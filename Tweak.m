#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
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

// ---------- Paramètres (écrits par l'UI, lus par le thread audio) ----------
static _Atomic float gBassDb = 0.0f;
static _Atomic float gTrebleDb = 0.0f;
static _Atomic float gGainDb = 0.0f;
static _Atomic float gSampleRate = 44100.0f;
static atomic_int gActive = 1;
static atomic_int outIsFloat;
static atomic_int cCallback;
static atomic_int peakPost;

// ---------- Biquads ----------
typedef struct { float b0, b1, b2, a1, a2; } Coef;
typedef struct { float z1, z2; } State;

static Coef gLow = {1, 0, 0, 0, 0};
static Coef gHigh = {1, 0, 0, 0, 0};
static State gState[2][2];            // [filtre][canal]
static float gCBass = -999.f, gCTreble = -999.f, gCRate = 0.f;
static float gCGain = 1.0f, gCGainDb = -999.f;

static Coef shelf(int high, float dB, float fs, float f0) {
    float A = powf(10.0f, dB / 40.0f);
    float w0 = 2.0f * (float)M_PI * f0 / fs;
    float cw = cosf(w0), sw = sinf(w0);
    float alpha = sw / 2.0f * sqrtf(2.0f);
    float sA = sqrtf(A);
    float b0, b1, b2, a0, a1, a2;
    if (!high) {
        b0 =      A * ((A + 1) - (A - 1) * cw + 2 * sA * alpha);
        b1 =  2 * A * ((A - 1) - (A + 1) * cw);
        b2 =      A * ((A + 1) - (A - 1) * cw - 2 * sA * alpha);
        a0 =           (A + 1) + (A - 1) * cw + 2 * sA * alpha;
        a1 =     -2 * ((A - 1) + (A + 1) * cw);
        a2 =           (A + 1) + (A - 1) * cw - 2 * sA * alpha;
    } else {
        b0 =      A * ((A + 1) + (A - 1) * cw + 2 * sA * alpha);
        b1 = -2 * A * ((A - 1) + (A + 1) * cw);
        b2 =      A * ((A + 1) + (A - 1) * cw - 2 * sA * alpha);
        a0 =           (A + 1) - (A - 1) * cw + 2 * sA * alpha;
        a1 =      2 * ((A - 1) - (A + 1) * cw);
        a2 =           (A + 1) - (A - 1) * cw - 2 * sA * alpha;
    }
    Coef c = { b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0 };
    return c;
}

static inline float biquad(const Coef *c, State *s, float x) {
    float y = c->b0 * x + s->z1;
    s->z1 = c->b1 * x - c->a1 * y + s->z2;
    s->z2 = c->b2 * x - c->a2 * y;
    return y;
}

static inline float processSample(float x, int ch) {
    x *= gCGain;
    x = biquad(&gLow, &gState[0][ch], x);
    x = biquad(&gHigh, &gState[1][ch], x);
    float a = fabsf(x);
    if (a > 0.9f) {
        float t = 0.9f + 0.1f * tanhf((a - 0.9f) / 0.1f);
        x = copysignf(t, x);
    }
    return x;
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
    if (!atomic_load(&gActive)) return st;

    float bass = atomic_load(&gBassDb);
    float treble = atomic_load(&gTrebleDb);
    float gdb = atomic_load(&gGainDb);
    float fs = atomic_load(&gSampleRate);
    if (bass != gCBass || fs != gCRate) { gLow = shelf(0, bass, fs, 100.0f); gCBass = bass; }
    if (treble != gCTreble || fs != gCRate) { gHigh = shelf(1, treble, fs, 8000.0f); gCTreble = treble; }
    gCRate = fs;
    if (gdb != gCGainDb) { gCGain = powf(10.0f, gdb / 20.0f); gCGainDb = gdb; }

    float post = 0.f;

    if (ioData->mNumberBuffers == 1) {
        UInt32 ch = ioData->mBuffers[0].mNumberChannels;
        if (ch == 0) ch = 2;
        float *s = (float *)ioData->mBuffers[0].mData;
        UInt32 n = ioData->mBuffers[0].mDataByteSize / sizeof(float);
        if (!s) return st;
        for (UInt32 i = 0; i < n; i++) {
            int c = (int)(i % ch); if (c > 1) c = 1;
            s[i] = processSample(s[i], c);
            float a = fabsf(s[i]); if (a > post) post = a;
        }
    } else {
        for (UInt32 b = 0; b < ioData->mNumberBuffers; b++) {
            float *s = (float *)ioData->mBuffers[b].mData;
            UInt32 n = ioData->mBuffers[b].mDataByteSize / sizeof(float);
            if (!s) continue;
            int c = b > 1 ? 1 : (int)b;
            for (UInt32 i = 0; i < n; i++) {
                s[i] = processSample(s[i], c);
                float a = fabsf(s[i]); if (a > post) post = a;
            }
        }
    }

    int p2 = (int)(post * 1000.f);
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
        FXLog([NSString stringWithFormat:@"StreamFormat rate=%.0f ch=%u float=%d",
               f->mSampleRate, (unsigned)f->mChannelsPerFrame, isFloat]);
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

// ================= UI =================

// Fenêtre qui laisse passer les touches sauf sur nos vues
@interface FXWindow : UIWindow
@end
@implementation FXWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *v = [super hitTest:point withEvent:event];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
@end

static FXWindow *gWindow;
static UIView *gPanel;
static BOOL gUIBuilt = NO;

static void saveParams(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setFloat:atomic_load(&gBassDb) forKey:@"fx_bass"];
    [d setFloat:atomic_load(&gTrebleDb) forKey:@"fx_treble"];
    [d setFloat:atomic_load(&gGainDb) forKey:@"fx_gain"];
    [d setBool:atomic_load(&gActive) forKey:@"fx_active"];
}

static void loadParams(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if ([d objectForKey:@"fx_bass"]) atomic_store(&gBassDb, [d floatForKey:@"fx_bass"]);
    if ([d objectForKey:@"fx_treble"]) atomic_store(&gTrebleDb, [d floatForKey:@"fx_treble"]);
    if ([d objectForKey:@"fx_gain"]) atomic_store(&gGainDb, [d floatForKey:@"fx_gain"]);
    if ([d objectForKey:@"fx_active"]) atomic_store(&gActive, [d boolForKey:@"fx_active"] ? 1 : 0);
}

@interface FXButtonTarget : NSObject
- (void)toggle;
@end
@implementation FXButtonTarget
- (void)toggle { gPanel.hidden = !gPanel.hidden; }
@end
static FXButtonTarget *gTarget;

static void addSlider(UIView *parent, NSString *name, CGFloat y, float min, float max, float initial,
                      void (^onChange)(float)) {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(16, y, 248, 20)];
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    label.text = [NSString stringWithFormat:@"%@ : %+.1f dB", name, initial];
    [parent addSubview:label];

    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(16, y + 22, 248, 30)];
    slider.minimumValue = min;
    slider.maximumValue = max;
    slider.value = initial;
    [slider addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
        float v = roundf(slider.value * 2.0f) / 2.0f;   // pas de 0.5 dB
        label.text = [NSString stringWithFormat:@"%@ : %+.1f dB", name, v];
        onChange(v);
        saveParams();
    }] forControlEvents:UIControlEventValueChanged];
    [parent addSubview:slider];
}

static void buildUI(void) {
    if (gUIBuilt) return;

    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            scene = (UIWindowScene *)s;
            if (s.activationState == UISceneActivationStateForegroundActive) break;
        }
    }
    if (!scene) return;   // on réessaiera à la prochaine activation

    gUIBuilt = YES;
    gWindow = [[FXWindow alloc] initWithWindowScene:scene];
    gWindow.frame = scene.coordinateSpace.bounds;
    gWindow.windowLevel = UIWindowLevelAlert + 100;
    gWindow.backgroundColor = UIColor.clearColor;
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.clearColor;
    gWindow.rootViewController = vc;
    gWindow.hidden = NO;

    gTarget = [FXButtonTarget new];

    // Bouton FX
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = CGRectMake(16, 70, 44, 44);
    btn.backgroundColor = [UIColor colorWithRed:0.11 green:0.73 blue:0.33 alpha:0.95];
    btn.layer.cornerRadius = 22;
    [btn setTitle:@"FX" forState:UIControlStateNormal];
    [btn setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [btn addTarget:gTarget action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [vc.view addSubview:btn];

    // Panel
    gPanel = [[UIView alloc] initWithFrame:CGRectMake(16, 122, 280, 290)];
    gPanel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    gPanel.layer.cornerRadius = 16;
    gPanel.hidden = YES;
    [vc.view addSubview:gPanel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 150, 24)];
    title.text = @"SpotifyFX";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:17];
    [gPanel addSubview:title];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(210, 8, 51, 31)];
    sw.on = atomic_load(&gActive) != 0;
    [sw addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
        atomic_store(&gActive, sw.on ? 1 : 0);
        saveParams();
    }] forControlEvents:UIControlEventValueChanged];
    [gPanel addSubview:sw];

    addSlider(gPanel, @"Basses", 52, -12, 12, atomic_load(&gBassDb), ^(float v) { atomic_store(&gBassDb, v); });
    addSlider(gPanel, @"Aigus", 118, -12, 12, atomic_load(&gTrebleDb), ^(float v) { atomic_store(&gTrebleDb, v); });
    addSlider(gPanel, @"Volume", 184, -12, 6, atomic_load(&gGainDb), ^(float v) { atomic_store(&gGainDb, v); });

    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    reset.frame = CGRectMake(16, 248, 248, 32);
    [reset setTitle:@"Réinitialiser" forState:UIControlStateNormal];
    [reset addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
        atomic_store(&gBassDb, 0.0f); atomic_store(&gTrebleDb, 0.0f); atomic_store(&gGainDb, 0.0f);
        saveParams();
        // reconstruit le panel avec les valeurs à zéro
        [gPanel removeFromSuperview];
        gUIBuilt = NO; gWindow.hidden = YES; gWindow = nil;
        buildUI();
        gPanel.hidden = NO;
    }] forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:reset];

    FXLog(@"Panel créé");
}

static dispatch_source_t keepTimer;

__attribute__((constructor))
static void init(void) {
    FXLog(@"SpotifyFX chargée (panel)");
    loadParams();

    rebind_symbols((struct rebinding[]){
        {"AudioUnitSetProperty", my_AudioUnitSetProperty, (void *)&orig_AudioUnitSetProperty},
    }, 1);

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(NSNotification *n) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            buildUI();
        });
    }];

    keepTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(keepTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, 0);
    dispatch_source_set_event_handler(keepTimer, ^{
        FXLog([NSString stringWithFormat:@"bass=%.1f treble=%.1f gain=%.1f active=%d cb=%d peak=%d",
               atomic_load(&gBassDb), atomic_load(&gTrebleDb), atomic_load(&gGainDb),
               atomic_load(&gActive), atomic_load(&cCallback), atomic_exchange(&peakPost, 0)]);
    });
    dispatch_resume(keepTimer);
}
