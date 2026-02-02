#ifndef AUDIOPROCESSOR_HPP
#define AUDIOPROCESSOR_HPP

#include <AudioUnit/AudioUnit.h>
#include <vector>
#include <iostream>
#include <algorithm>

// Global gain control for safety
extern float globalGain;

// Audio Render Callback
static OSStatus AudioRenderCallback(
    void *inRefCon,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData) {

    AudioUnit *remoteIOUnit = (AudioUnit *)inRefCon;

    // 1. Get audio from Microphone (Input Bus 1)
    // We reuse ioData's buffers if possible, or use a temp buffer if necessary.
    // For simplicity in this callback, we ask the unit to render input into ioData.
    
    // Note: To pull input, we must call AudioUnitRender on the same unit (HAL Output unit)
    // but requesting audio from Bus 1 (Input).
    
    OSStatus status = AudioUnitRender(*remoteIOUnit,
                                      ioActionFlags,
                                      inTimeStamp,
                                      1, // Input bus
                                      inNumberFrames,
                                      ioData);

    if (status != noErr) {
        return status;
    }

    // 2. Process Audio (Phase Inversion)
    // ioData contains the microphone input now.
    // We traverse all buffers (channels).
    for (UInt32 i = 0; i < ioData->mNumberBuffers; ++i) {
        float *buffer = (float *)ioData->mBuffers[i].mData;
        // The data might be interleaved or non-interleaved depending on format setup.
        // Assuming non-interleaved float 32-bit for simplicity as requested in setup.
        
        if (buffer) {
            for (UInt32 frame = 0; frame < inNumberFrames; ++frame) {
                // INVERT PHASE: Output = -Input
                // Apply global gain for safety volume control
                buffer[frame] = -buffer[frame] * globalGain;
            }
        }
    }

    return noErr;
}

#endif // AUDIOPROCESSOR_HPP
