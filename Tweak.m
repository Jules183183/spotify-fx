#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include "fishhook.h"
#include <stdatomic.h>
#include <stdlib.h>

static void FXLog(NSString *msg) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *path = [dir stringByAppendingPathComponent:@"fx_log.txt"];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

static atomic_int cSetProp, cCallback;
static atomic_int outIsFloat;      // 1 si le format de sortie est float 32 bits
static float gTestGain = 0.3f;     // volume de test

// Infos du callback original de Spotify
typedef struct {
    AURenderCallback proc;
    void *refCon;
} FXWrap;

// Notre callback : appelé par le système sur le thread audio (pas de log, pas d'ObjC ici)
static OSStatus fx_render(void *inRefCon,
                          AudioUnitRenderActionFlags *ioActionFlags,
                          const AudioTimeStamp *inTimeStamp,
                          UInt32 inBusNumber,
                          UInt32 inNumberFrames,
                          AudioBufferList *ioData) {
    FXWrap *w = (FXWrap *)inRefCon;
    OSStatus st = w->proc(w->refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    atomic_fetch_add(&cCallback, 1);

    if (st == noErr && ioData && atomic_load(&outIsFloat) &&
        !(*ioActionFlags & kAudioUnitRenderAction_OutputIsSilence)) {
        for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
            float *samples = (float *)ioData->mBuffers[b].mData;
            UInt32 n = ioData->mBuffers[b].mDataByteSize / sizeof(float);
            if (!samples) continue;
            for (UInt32 i = 0; i < n; i++) {
                samples[i] *= gTestGain;
            }
        }
    }
    return st;
}

static OSStatus (*orig_AudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
static OSStatus my_AudioUnitSetProperty(AudioUnit u, AudioUnitPropertyID p, AudioUnitScope s, AudioUnitElement e, const void *d, UInt32 sz) {
    atomic_fetch_add(&cSetProp, 1);

    if (p == kAudioUnitProperty_StreamFormat && s == kAudioUnitScope_Input && d && sz >= sizeof(AudioStreamBasicDescription)) {
        const AudioStreamBasicDescription *f = (const AudioStreamBasicDescription *)d;
        int isFloat = (f->mFormatID == kAudioFormatLinearPCM) &&
                      (f->mFormatFlags & kAudioFormatFlagIsFloat) &&
                      f->mBitsPerChannel == 32;
        atomic_store(&outIsFloat, isFloat);
        FXLog([NSString stringWithFormat:@"StreamFormat scope=%u rate=%.0f flags=0x%x bits=%u ch=%u float=%d",
               (unsigned)s, f->mSampleRate, (unsigned)f->mFormatFlags, (unsigned)f->mBitsPerChannel, (unsigned)f->mChannelsPerFrame, isFloat]);
    }

    if (p == kAudioUnitProperty_SetRenderCallback && s == kAudioUnitScope_Input && d && sz >= sizeof(AURenderCallbackStruct)) {
        const AURenderCallbackStruct *cb = (const AURenderCallbackStruct *)d;
        if (cb->inputProc) {
            FXWrap *w = (FXWrap *)malloc(sizeof(FXWrap));
            w->proc = cb->inputProc;
            w->refCon = cb->inputProcRefCon;
            AURenderCallbackStruct mine;
            mine.inputProc = fx_render;
            mine.inputProcRefCon = w;
            FXLog([NSString stringWithFormat:@"Callback remplacé scope=%u elem=%u orig=%p", (unsigned)s, (unsigned)e, cb->inputProc]);
            return orig_AudioUnitSetProperty(u, p, s, e, &mine, sizeof(mine));
        }
    }
    return orig_AudioUnitSetProperty(u, p, s, e, d, sz);
}

static dispatch_source_t keepTimer;

__attribute__((constructor))
static void init(void) {
    FXLog(@"SpotifyFX chargée");

    rebind_symbols((struct rebinding[]){
        {"AudioUnitSetProperty", my_AudioUnitSetProperty, (void *)&orig_AudioUnitSetProperty},
    }, 1);

    keepTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(keepTimer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, 0);
    dispatch_source_set_event_handler(keepTimer, ^{
        FXLog([NSString stringWithFormat:@"setProp=%d callbacks=%d float=%d",
               atomic_load(&cSetProp), atomic_load(&cCallback), atomic_load(&outIsFloat)]);
    });
    dispatch_resume(keepTimer);
}
