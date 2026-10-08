#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include "fishhook.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <math.h>

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

static atomic_int cSetProp, cCallback, cModified, cSilent, cError;
static atomic_int outIsFloat;
static atomic_int lastBuffers, lastBytes, lastFrames, lastFlags, lastStatus;
static atomic_int peakPre, peakPost;   // niveau x1000 (1000 = pleine échelle)
static float gTestGain = 0.0f;         // TEST : 0 = silence total

typedef struct {
    AURenderCallback proc;
    void *refCon;
} FXWrap;

static OSStatus fx_render(void *inRefCon,
                          AudioUnitRenderActionFlags *ioActionFlags,
                          const AudioTimeStamp *inTimeStamp,
                          UInt32 inBusNumber,
                          UInt32 inNumberFrames,
                          AudioBufferList *ioData) {
    FXWrap *w = (FXWrap *)inRefCon;
    OSStatus st = w->proc(w->refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    atomic_fetch_add(&cCallback, 1);
    atomic_store(&lastStatus, (int)st);
    atomic_store(&lastFrames, (int)inNumberFrames);
    UInt32 flags = ioActionFlags ? *ioActionFlags : 0;
    atomic_store(&lastFlags, (int)flags);

    if (st != noErr) { atomic_fetch_add(&cError, 1); return st; }
    if (!ioData) return st;
    atomic_store(&lastBuffers, (int)ioData->mNumberBuffers);
    atomic_store(&lastBytes, (int)ioData->mBuffers[0].mDataByteSize);

    if (flags & kAudioUnitRenderAction_OutputIsSilence) {
        atomic_fetch_add(&cSilent, 1);
        return st;
    }
    if (!atomic_load(&outIsFloat)) return st;

    float pre = 0.f, post = 0.f;
    for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
        float *samples = (float *)ioData->mBuffers[b].mData;
        UInt32 n = ioData->mBuffers[b].mDataByteSize / sizeof(float);
        if (!samples) continue;
        for (UInt32 i = 0; i < n; i++) {
            float a = fabsf(samples[i]);
            if (a > pre) pre = a;
            samples[i] *= gTestGain;
            a = fabsf(samples[i]);
            if (a > post) post = a;
        }
    }
    atomic_fetch_add(&cModified, 1);
    int p1 = (int)(pre * 1000.f), p2 = (int)(post * 1000.f);
    if (p1 > atomic_load(&peakPre)) atomic_store(&peakPre, p1);
    if (p2 > atomic_load(&peakPost)) atomic_store(&peakPost, p2);
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
        FXLog([NSString stringWithFormat:@"StreamFormat rate=%.0f flags=0x%x bits=%u ch=%u float=%d",
               f->mSampleRate, (unsigned)f->mFormatFlags, (unsigned)f->mBitsPerChannel, (unsigned)f->mChannelsPerFrame, isFloat]);
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
            FXLog([NSString stringWithFormat:@"Callback remplacé elem=%u orig=%p unit=%p", (unsigned)e, cb->inputProc, u]);
            return orig_AudioUnitSetProperty(u, p, s, e, &mine, sizeof(mine));
        }
    }
    return orig_AudioUnitSetProperty(u, p, s, e, d, sz);
}

static dispatch_source_t keepTimer;

__attribute__((constructor))
static void init(void) {
    FXLog(@"SpotifyFX chargée (test silence)");

    rebind_symbols((struct rebinding[]){
        {"AudioUnitSetProperty", my_AudioUnitSetProperty, (void *)&orig_AudioUnitSetProperty},
    }, 1);

    keepTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(keepTimer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, 0);
    dispatch_source_set_event_handler(keepTimer, ^{
        FXLog([NSString stringWithFormat:@"cb=%d modif=%d silent=%d err=%d bufs=%d bytes=%d frames=%d flags=0x%x status=%d peakAvant=%d peakApres=%d",
               atomic_load(&cCallback), atomic_load(&cModified), atomic_load(&cSilent), atomic_load(&cError),
               atomic_load(&lastBuffers), atomic_load(&lastBytes), atomic_load(&lastFrames),
               (unsigned)atomic_load(&lastFlags), atomic_load(&lastStatus),
               atomic_exchange(&peakPre, 0), atomic_exchange(&peakPost, 0)]);
    });
    dispatch_resume(keepTimer);
}
