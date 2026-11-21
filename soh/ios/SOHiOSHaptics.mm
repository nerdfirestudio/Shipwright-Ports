#import "SOHiOSHaptics.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreHaptics/CoreHaptics.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>   // CACurrentMediaTime

#include <atomic>
#include <cmath>

// All Core Haptics work happens on one serial queue; the game thread only does cheap bookkeeping and posts
// a change when the smoothed state actually moves.
namespace {
dispatch_queue_t Queue() {
    static dispatch_queue_t q = dispatch_queue_create("soh.haptics", DISPATCH_QUEUE_SERIAL);
    return q;
}

CHHapticEngine* gEngine = nil;            // the app targets iOS 15+, where Core Haptics always exists
id<CHHapticAdvancedPatternPlayer> gPlayer = nil;
bool gEngineRunning = false;
bool gPlaying = false;
float gIntensity = 0.0f;
CFTimeInterval gLastFallbackBuzz = 0;

// Game-thread state: a short history of the rumble bit, so on/off flicker reads as one vibration.
constexpr int kWindow = 8;          // ticks of history used for strength
constexpr double kHold = 0.12;      // seconds the vibration outlasts the last "on" tick
uint8_t gHistory[kWindow] = {};
int gHistoryPos = 0;
double gLastOn = 0;
std::atomic<bool> gWantPlaying{false};
float gPostedIntensity = -1.0f;

bool Supported() {
    return CHHapticEngine.capabilitiesForHardware.supportsHaptics;
}

bool EnsureEngine() {
    if (gEngine == nil) {
        NSError* err = nil;
        gEngine = [[CHHapticEngine alloc] initAndReturnError:&err];
        if (gEngine == nil) return false;
        gEngine.playsHapticsOnly = YES;
        gEngine.autoShutdownEnabled = YES;    // powers down between rumbles, restarts on the next one
        gEngine.stoppedHandler = ^(CHHapticEngineStoppedReason) {
            dispatch_async(Queue(), ^{ gEngineRunning = false; gPlayer = nil; gPlaying = false; });
        };
        gEngine.resetHandler = ^{
            dispatch_async(Queue(), ^{ gEngineRunning = false; gPlayer = nil; gPlaying = false; });
        };
    }
    if (!gEngineRunning) {
        NSError* err = nil;
        if (![gEngine startAndReturnError:&err]) return false;
        gEngineRunning = true;
    }
    return true;
}

void StartContinuous(float intensity) {
    if (!EnsureEngine()) return;
    NSError* err = nil;
    if (gPlayer == nil) {
        // the longest single continuous event Core Haptics allows; it is renewed if a rumble ever runs longer
        CHHapticEvent* ev = [[CHHapticEvent alloc]
            initWithEventType:CHHapticEventTypeHapticContinuous
                   parameters:@[ [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1.0],
                                 [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.25] ]
                 relativeTime:0
                     duration:30];
        CHHapticPattern* pattern = [[CHHapticPattern alloc] initWithEvents:@[ ev ] parameters:@[] error:&err];
        if (pattern == nil) return;
        gPlayer = [gEngine createAdvancedPlayerWithPattern:pattern error:&err];
        if (gPlayer == nil) return;
        gPlayer.loopEnabled = YES;
    }
    CHHapticDynamicParameter* p = [[CHHapticDynamicParameter alloc]
        initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:intensity relativeTime:0];
    if (!gPlaying) {
        if ([gPlayer startAtTime:CHHapticTimeImmediate error:&err]) gPlaying = true;
    }
    [gPlayer sendParameters:@[ p ] atTime:CHHapticTimeImmediate error:&err];
    gIntensity = intensity;
}

void StopContinuous() {
    if (gPlayer != nil && gPlaying) {
        NSError* err = nil;
        [gPlayer stopAtTime:CHHapticTimeImmediate error:&err];
    }
    gPlaying = false;
}

void Apply(bool play, float intensity) {
    dispatch_async(Queue(), ^{
        if (Supported()) {
            if (play) StartContinuous(intensity); else StopContinuous();
        } else if (play) {
            // no Taptic Engine: the plain system vibrate, at most twice a second so it never stacks up
            CFTimeInterval now = CACurrentMediaTime();
            if (now - gLastFallbackBuzz > 0.5) {
                gLastFallbackBuzz = now;
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
            }
        }
    });
}
} // namespace

extern "C" int SOHiOS_PhoneRumbleAvailable(void) {
    return 1;   // every iPhone can vibrate; Core Haptics when present, the system vibrate otherwise
}

extern "C" void SOHiOS_UpdatePhoneRumble(int on, float strength) {
    double now = CACurrentMediaTime();
    gHistory[gHistoryPos] = on ? 1 : 0;
    gHistoryPos = (gHistoryPos + 1) % kWindow;
    if (on) gLastOn = now;

    int count = 0;
    for (int i = 0; i < kWindow; i++) count += gHistory[i];
    bool want = (now - gLastOn) < kHold;
    // strength follows the game's pulse rate (its "how hard" signal), never so faint it can't be felt
    float duty = count / (float)kWindow;
    float intensity = std::fmax(0.0f, std::fmin(1.0f, strength * (0.45f + 0.55f * duty)));

    bool was = gWantPlaying.load();
    if (want != was) {
        gWantPlaying.store(want);
        gPostedIntensity = intensity;
        Apply(want, intensity);
    } else if (want && std::fabs(intensity - gPostedIntensity) > 0.12f) {
        gPostedIntensity = intensity;
        Apply(true, intensity);
    }
}

extern "C" void SOHiOS_TestPhoneRumble(float strength) {
    float s = std::fmax(0.1f, std::fmin(1.0f, strength));
    Apply(true, s);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!gWantPlaying.load()) Apply(false, 0);
    });
}

extern "C" void SOHiOS_StopPhoneRumble(void) {
    gWantPlaying.store(false);
    for (int i = 0; i < kWindow; i++) gHistory[i] = 0;
    Apply(false, 0);
}
