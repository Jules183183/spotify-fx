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

// ---------- Paramètres (écrits par l'UI/timer, lus par le thread audio) ----------
static _Atomic float gBassDb = 0.0f;
static _Atomic float gSampleRate = 44100.0f;
static atomic_int outIsFloat;
static atomic_int cCallback, cModified;
static atomic_int peakPre, peakPost;

// ---------- Biquad low-shelf ----------
typedef struct { float b0, b1, b2, a1, a2; } Coef;
typedef struct { float z1, z2; } State;

static Coef gCoef = {1, 0, 0, 0, 0};
static State gState[2];
static float gCachedDb = -999.f, gCachedRate = 0.f;

static void computeLowShelf(float dB, float fs, float f0) {
    float A = powf(10.0f, dB / 40.0f);
    float w0 = 2.0f * (float)M_PI * f0 / fs;
    float cw = cosf(w0), sw = sinf(w0);
    float alpha = sw / 2.0f * sqrtf(2.0f);   // pente S = 1
    float sA = sqrtf(A);
    float b0 =      A * ((A + 1) - (A - 1) * cw + 2 * sA * alpha);
    float b1 =  2 * A * ((A - 1) - (A + 1) * cw);
    float b2 =      A * ((A + 1) - (A - 1) * cw - 2 * sA * alpha);
    float a0 =           (A + 1) + (A - 1) * cw + 2 * sA * alpha;
    float a1 =     -2 * ((A - 1) + (A + 1) * cw);
    float a2 =           (A + 1) + (A - 1) * cw - 2 * sA * alpha;
    gCoef.b0 = b0 / a0; gCoef.b1 = b1 / a0; gCoef.b2 = b2 / a0;
    gCoef.a1 = a1 / a0; gCoef.a2 = a2 / a0;
}

static inline float processSample(float x, int ch) {
    State *s = &gState[ch];
    float y = gCoef.b0 * x + s->z1;
    s->z1 = gCoef.b1 * x - gCoef.a1 * y + s->z2;
    s->z2 = gCoef.b2 * x - gCoef.a2 * y;
    // limiteur doux au-dessus de 0.9
    float a = fabsf(y);
    if (a > 0.9f) {
        float t = 0.9f + 0.1f * tanhf((a - 0.9f) / 0.1f);
        y = copysignf(t, y);
    }
    return y;
}

typedef struct {
    AURenderCallback proc;
    void *refCon;
} FXWrap;

// Callback audio : thread temps réel (pas de log, pas d'ObjC, pas de malloc)
static OSStatus fx_render(void *inRefCon,
                          AudioUnitRenderActionFlags *ioActionFlags,
                          const AudioTimeStamp *inTimeStamp,
                          UInt32 inBusNumber,
                          UInt32 inNumberFrames,
                          AudioBufferList *ioData) {
    FXWrap *w = (FXWrap *)inRefCon;
    OSStatus st = w->proc(w->refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    atomic_fetch_add(&cCallback, 1);

    if (st != noErr || !ioData) return st;
    UInt32 flags = ioActionFlags ? *ioActionFlags : 0;
    if (flags & kAudioUnitRenderAction_OutputIsSilence) return st;
    if (!atomic_load(&outIsFloat)) return st;

    // Recalcul des coefficients seulement si les paramètres ont changé
    float db = atomic_load(&gBassDb);
    float fs = atomic_load(&gSampleRate);
    if (db != gCachedDb || fs != gCachedRate) {
        computeLowShelf(db, fs, 100.0f);
        gCachedDb = db; gCachedRate = fs;
    }

    float pre = 0.f, post = 0.f;

    if (ioData->mNumberBuffers == 1) {
        // Entrelacé : G D G D ...
        UInt32 ch = ioData->mBuffers[0].mNumberChannels;
        if (ch == 0) ch = 2;
        float *s = (float *)ioData->mBuffers[0].mData;
        UInt32 n = ioData->mBuffers[0].mDataByteSize / sizeof(float);
        if (!s) return st;
        for (UInt32 i = 0; i < n; i++) {
            int c = (int)(i % ch); if (c > 1) c = 1;
            float a = fabsf(s[i]); if (a > pre) pre = a;
            s[i] = processSample(s[i], c);
            a = fabsf(s[i]); if (a > post) post = a;
        }
    } else {
        // Non entrelacé : un buffer par canal
        for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
            float *s = (float *)ioData->mBuffers[b].mData;
            UInt32 n = ioData->mBuffers[b].mDataByteSize / sizeof(float);
            if (!s) continue;
            int c = b > 1 ? 1 : (int)b;
            for (UInt32 i = 0; i < n; i++) {
                float a = fabsf(s[i]); if (a > pre) pre = a;
                s[i] = processSample(s[i], c);
                a = fabsf(s[i]); if (a > post) post = a;
            }
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
    if (p == kAudioUnitProperty_StreamFormat && s == kAudioUnitScope_Input && d && sz >= sizeof(AudioStreamBasicDescription)) {
        const AudioStreamBasicDescription *f = (const AudioStreamBasicDescription *)d;
        int isFloat = (f->mFormatID == kAudioFormatLinearPCM) &&
                      (f->mFormatFlags & kAudioFormatFlagIsFloat) &&
                      f->mBitsPerChannel == 32;
        atomic_store(&outIsFloat, isFloat);
        if (f->mSampleRate > 0) atomic_store(&gSampleRate, (float)f->mSampleRate);
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
            FXLog([NSString stringWithFormat:@"Callback remplacé elem=%u orig=%p", (unsigned)e, cb->inputProc]);
            return orig_AudioUnitSetProperty(u, p, s, e, &mine, sizeof(mine));
        }
    }
    return orig_AudioUnitSetProperty(u, p, s, e, d, sz);
}

static dispatch_source_t keepTimer;
static int tick = 0;

__attribute__((constructor))
static void init(void) {
    FXLog(@"SpotifyFX chargée (test EQ basses A/B)");

    rebind_symbols((struct rebinding[]){
        {"AudioUnitSetProperty", my_AudioUnitSetProperty, (void *)&orig_AudioUnitSetProperty},
    }, 1);

    keepTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(keepTimer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, 0);
    dispatch_source_set_event_handler(keepTimer, ^{
        tick++;
        // Test A/B : change toutes les 6 s (2 ticks de 3 s)
        if (tick % 2 == 0) {
            float cur = atomic_load(&gBassDb);
            atomic_store(&gBassDb, cur == 0.0f ? 12.0f : 0.0f);
        }
        FXLog([NSString stringWithFormat:@"bass=%.0fdB cb=%d modif=%d peakAvant=%d peakApres=%d",
               atomic_load(&gBassDb), atomic_load(&cCallback), atomic_load(&cModified),
               atomic_exchange(&peakPre, 0), atomic_exchange(&peakPost, 0)]);
    });
    dispatch_resume(keepTimer);
}
