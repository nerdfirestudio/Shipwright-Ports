#pragma once

// iPhone vibration for the game's rumble (Justin, 2026-11-20: "I want it to rumble on my iphone").
// The N64 drove its Rumble Pak by switching the motor on and off every frame; this turns that into one smooth
// Core Haptics vibration whose strength follows how often the game is pulsing. Without a Taptic Engine it
// falls back to the system vibrate, rate limited.
#ifdef __cplusplus
extern "C" {
#endif

int SOHiOS_PhoneRumbleAvailable(void);
// Called every game tick with the game's rumble bit. strength is 0..1 from the menu slider.
void SOHiOS_UpdatePhoneRumble(int on, float strength);
// One short buzz at this strength, for the menu's Test button.
void SOHiOS_TestPhoneRumble(float strength);
void SOHiOS_StopPhoneRumble(void);

#ifdef __cplusplus
}
#endif
