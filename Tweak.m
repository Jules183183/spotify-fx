#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#include "fishhook.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
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

// ================= PARAMÈTRES =================

typedef enum {
    P_VOL, P_BASS, P_MID, P_TREBLE, P_BASSF, P_TREBF,
    P_WIDTH, P_BAL, P_SAT,
    P_REVMIX, P_REVSIZE, P_REVDAMP,
    P_ECHOMIX, P_ECHOTIME, P_ECHOFB,
    P_COUNT
} ParamId;

typedef struct { const char *name; const char *unit; float min, max, def; } ParamDef;

static const ParamDef kDefs[P_COUNT] = {
    {"Volume",            "dB", -40,  30,    0},
    {"Basses",            "dB", -30,  30,    0},
    {"Médiums",           "dB", -30,  30,    0},
    {"Aigus",             "dB", -30,  30,    0},
    {"Fréquence basses",  "Hz",  40, 400,  100},
    {"Fréquence aigus",   "Hz", 2000, 14000, 8000},
    {"Largeur stéréo",    "%",    0, 300,  100},
    {"Balance G/D",       "%", -100, 100,    0},
    {"Saturation",        "%",    0, 100,    0},
    {"Reverb mix",        "%",    0, 200,    0},
    {"Reverb taille",     "%",    0, 100,   50},
    {"Reverb amorti",     "%",    0, 100,   50},
    {"Écho mix",          "%",    0, 150,    0},
    {"Écho délai",        "ms",  20, 1500, 350},
    {"Écho répétitions",  "%",    0,  95,   35},
};

static _Atomic float gP[P_COUNT];
static _Atomic float gSampleRate = 44100.0f;
static atomic_int gActive = 1;
static atomic_int outIsFloat;
static atomic_int cCallback;
static atomic_int peakPost;

#define GP(i) atomic_load_explicit(&gP[i], memory_order_relaxed)

// ================= DSP =================

typedef struct { float b0, b1, b2, a1, a2; } Coef;
typedef struct { float z1, z2; } State;

static Coef gCoef[3] = {{1,0,0,0,0},{1,0,0,0,0},{1,0,0,0,0}};   // 0 basses, 1 médiums, 2 aigus
static State gSt[3][2];
static float gCEq[6] = {-999,-999,-999,-999,-999,-999};

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

static Coef peaking(float dB, float fs, float f0, float Q) {
    float A = powf(10.0f, dB / 40.0f);
    float w0 = 2.0f * (float)M_PI * f0 / fs;
    float cw = cosf(w0), alpha = sinf(w0) / (2.0f * Q);
    float b0 = 1 + alpha * A, b1 = -2 * cw, b2 = 1 - alpha * A;
    float a0 = 1 + alpha / A, a1 = -2 * cw, a2 = 1 - alpha / A;
    Coef c = { b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0 };
    return c;
}

static inline float biq(const Coef *c, State *s, float x) {
    float y = c->b0 * x + s->z1;
    s->z1 = c->b1 * x - c->a1 * y + s->z2;
    s->z2 = c->b2 * x - c->a2 * y;
    return y;
}

static inline float limiter(float x) {
    float a = fabsf(x);
    if (a > 0.9f) {
        float t = 0.9f + 0.1f * tanhf((a - 0.9f) / 0.1f);
        return copysignf(t, x);
    }
    return x;
}

// ---- Reverb (type Freeverb) ----
#define COMB_N 8
#define AP_N 4
#define COMB_MAX 4096
#define AP_MAX 2048
static const int kCombT[COMB_N] = {1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617};
static const int kApT[AP_N] = {556, 441, 341, 225};
static const int kSpread = 23;

static float combBuf[2][COMB_N][COMB_MAX];
static float combStore[2][COMB_N];
static int combIdx[2][COMB_N], combLen[2][COMB_N];
static float apBuf[2][AP_N][AP_MAX];
static int apIdx[2][AP_N], apLen[2][AP_N];

static void setReverbLengths(float fs) {
    float sc = fs / 44100.0f;
    for (int c = 0; c < 2; c++) {
        for (int i = 0; i < COMB_N; i++) {
            int l = (int)((kCombT[i] + c * kSpread) * sc);
            if (l < 1) l = 1; if (l > COMB_MAX) l = COMB_MAX;
            combLen[c][i] = l; combIdx[c][i] = 0;
        }
        for (int i = 0; i < AP_N; i++) {
            int l = (int)((kApT[i] + c * kSpread) * sc);
            if (l < 1) l = 1; if (l > AP_MAX) l = AP_MAX;
            apLen[c][i] = l; apIdx[c][i] = 0;
        }
    }
}

// ---- Écho (ping-pong) ----
#define ECHO_MAX 192000
static float echoBuf[2][ECHO_MAX];
static int echoIdx = 0;
static float gCRate = 0.f;

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

    // Accès aux canaux (entrelacé ou non)
    float *pl = NULL, *pr = NULL;
    UInt32 stride = 1, frames = 0;
    if (ioData->mNumberBuffers == 1) {
        UInt32 ch = ioData->mBuffers[0].mNumberChannels;
        if (ch == 0) ch = 2;
        if (ch != 2) return st;
        pl = (float *)ioData->mBuffers[0].mData;
        if (!pl) return st;
        pr = pl + 1; stride = 2;
        frames = ioData->mBuffers[0].mDataByteSize / (sizeof(float) * 2);
    } else if (ioData->mNumberBuffers >= 2) {
        pl = (float *)ioData->mBuffers[0].mData;
        pr = (float *)ioData->mBuffers[1].mData;
        if (!pl || !pr) return st;
        stride = 1;
        UInt32 a = ioData->mBuffers[0].mDataByteSize, b = ioData->mBuffers[1].mDataByteSize;
        frames = (a < b ? a : b) / sizeof(float);
    } else return st;

    // --- Lecture des paramètres ---
    float fs = atomic_load(&gSampleRate);
    float eq[6] = { GP(P_BASS), GP(P_MID), GP(P_TREBLE), GP(P_BASSF), GP(P_TREBF), fs };
    int changed = 0;
    for (int i = 0; i < 6; i++) if (eq[i] != gCEq[i]) changed = 1;
    if (changed) {
        float tf = eq[4]; if (tf > fs * 0.45f) tf = fs * 0.45f;
        gCoef[0] = shelf(0, eq[0], fs, eq[3]);
        gCoef[1] = peaking(eq[1], fs, 1000.0f, 0.7f);
        gCoef[2] = shelf(1, eq[2], fs, tf);
        for (int i = 0; i < 6; i++) gCEq[i] = eq[i];
    }
    if (fs != gCRate) { setReverbLengths(fs); gCRate = fs; }

    float volLin = powf(10.0f, GP(P_VOL) / 20.0f);
    float satAmt = GP(P_SAT) / 100.0f;
    float drive = 1.0f + satAmt * 8.0f;
    float satComp = 1.0f / sqrtf(drive);
    float width = GP(P_WIDTH) / 100.0f;
    float bal = GP(P_BAL) / 100.0f;
    float gl = bal > 0 ? 1.0f - bal : 1.0f;
    float gr = bal < 0 ? 1.0f + bal : 1.0f;

    float revMix = GP(P_REVMIX) / 100.0f;
    float revFb = 0.7f + 0.28f * (GP(P_REVSIZE) / 100.0f);
    float damp = (GP(P_REVDAMP) / 100.0f) * 0.4f;
    float wetGain = revMix * 3.0f;
    float dryGain = 1.0f - 0.4f * (revMix > 1.0f ? 1.0f : revMix);
    int doRev = revMix > 0.001f;

    float echoMix = GP(P_ECHOMIX) / 100.0f;
    float echoFb = GP(P_ECHOFB) / 100.0f;
    int echoDelay = (int)(GP(P_ECHOTIME) * 0.001f * fs);
    if (echoDelay < 1) echoDelay = 1;
    if (echoDelay > ECHO_MAX - 1) echoDelay = ECHO_MAX - 1;

    float post = 0.f;

    for (UInt32 i = 0; i < frames; i++) {
        float l = pl[i * stride], r = pr[i * stride];

        // EQ : basses, médiums, aigus
        l = biq(&gCoef[0], &gSt[0][0], l); l = biq(&gCoef[1], &gSt[1][0], l); l = biq(&gCoef[2], &gSt[2][0], l);
        r = biq(&gCoef[0], &gSt[0][1], r); r = biq(&gCoef[1], &gSt[1][1], r); r = biq(&gCoef[2], &gSt[2][1], r);

        // Saturation
        if (satAmt > 0.001f) {
            float wl = tanhf(l * drive) * satComp, wr = tanhf(r * drive) * satComp;
            l += (wl - l) * satAmt; r += (wr - r) * satAmt;
        }

        // Largeur stéréo + balance
        float m = (l + r) * 0.5f, s = (l - r) * 0.5f * width;
        l = (m + s) * gl; r = (m - s) * gr;

        // Écho ping-pong (le tampon est toujours alimenté)
        int ri = echoIdx - echoDelay; if (ri < 0) ri += ECHO_MAX;
        float dl = echoBuf[0][ri], dr = echoBuf[1][ri];
        echoBuf[0][echoIdx] = l + dr * echoFb;
        echoBuf[1][echoIdx] = r + dl * echoFb;
        if (++echoIdx >= ECHO_MAX) echoIdx = 0;
        l += dl * echoMix; r += dr * echoMix;

        // Reverb
        if (doRev) {
            float in = (l + r) * 0.015f;
            float sum[2] = {0, 0};
            for (int c = 0; c < 2; c++) {
                for (int k = 0; k < COMB_N; k++) {
                    float *buf = combBuf[c][k];
                    int idx = combIdx[c][k];
                    float o = buf[idx];
                    float fsv = o * (1.0f - damp) + combStore[c][k] * damp;
                    if (fabsf(fsv) < 1e-20f) fsv = 0.f;
                    combStore[c][k] = fsv;
                    buf[idx] = in + fsv * revFb;
                    if (++idx >= combLen[c][k]) idx = 0;
                    combIdx[c][k] = idx;
                    sum[c] += o;
                }
                for (int k = 0; k < AP_N; k++) {
                    float *buf = apBuf[c][k];
                    int idx = apIdx[c][k];
                    float bo = buf[idx];
                    float inp = sum[c];
                    sum[c] = -inp + bo;
                    buf[idx] = inp + bo * 0.5f;
                    if (++idx >= apLen[c][k]) idx = 0;
                    apIdx[c][k] = idx;
                }
            }
            l = l * dryGain + sum[0] * wetGain;
            r = r * dryGain + sum[1] * wetGain;
        }

        // Volume + limiteur
        l = limiter(l * volLin); r = limiter(r * volLin);
        pl[i * stride] = l; pr[i * stride] = r;

        float a = fabsf(l); if (a > post) post = a;
        a = fabsf(r); if (a > post) post = a;
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
static UIViewController *gVC;
static UIView *gPanel;
static UIButton *gBtn;
static BOOL gUIBuilt = NO;
static NSMutableArray<UISlider *> *gSliders;
static NSMutableArray<UILabel *> *gLabels;

static void saveParams(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    for (int i = 0; i < P_COUNT; i++) [d setFloat:GP(i) forKey:[NSString stringWithFormat:@"fx2_%d", i]];
    [d setBool:atomic_load(&gActive) forKey:@"fx2_active"];
}

static void loadParams(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    for (int i = 0; i < P_COUNT; i++) {
        NSString *k = [NSString stringWithFormat:@"fx2_%d", i];
        float v = [d objectForKey:k] ? [d floatForKey:k] : kDefs[i].def;
        if (v < kDefs[i].min) v = kDefs[i].min;
        if (v > kDefs[i].max) v = kDefs[i].max;
        atomic_store(&gP[i], v);
    }
    if ([d objectForKey:@"fx2_active"]) atomic_store(&gActive, [d boolForKey:@"fx2_active"] ? 1 : 0);
}

static NSString *labelText(int i, float v) {
    NSString *n = [NSString stringWithUTF8String:kDefs[i].name];
    if (!strcmp(kDefs[i].unit, "dB")) return [NSString stringWithFormat:@"%@ : %+.1f dB", n, v];
    return [NSString stringWithFormat:@"%@ : %.0f %s", n, v, kDefs[i].unit];
}

static void clampButton(void) {
    CGRect b = gVC.view.bounds;
    UIEdgeInsets in = gVC.view.safeAreaInsets;
    CGFloat minX = in.left + 26, maxX = b.size.width - in.right - 26;
    CGFloat minY = in.top + 26, maxY = b.size.height - in.bottom - 26;
    CGPoint c = gBtn.center;
    if (c.x < minX) c.x = minX; if (c.x > maxX) c.x = maxX;
    if (c.y < minY) c.y = minY; if (c.y > maxY) c.y = maxY;
    gBtn.center = c;
}

static void layoutPanel(void) {
    CGRect b = gVC.view.bounds;
    UIEdgeInsets in = gVC.view.safeAreaInsets;
    CGFloat pw = MIN(300.0, b.size.width - 16);
    CGFloat avail = b.size.height - in.top - in.bottom - 16;
    CGFloat ph = MIN(480.0, avail);
    CGFloat x = gBtn.frame.origin.x;
    if (x > b.size.width - pw - 8) x = b.size.width - pw - 8;
    if (x < 8) x = 8;
    CGFloat y = CGRectGetMaxY(gBtn.frame) + 8;
    if (y + ph > b.size.height - in.bottom - 8) {
        y = gBtn.frame.origin.y - 8 - ph;
        if (y < in.top + 8) y = MAX(in.top + 8, b.size.height - in.bottom - 8 - ph);
    }
    gPanel.frame = CGRectMake(x, y, pw, ph);
}

@interface FXTarget : NSObject
- (void)toggle;
- (void)pan:(UIPanGestureRecognizer *)g;
- (void)reset;
@end
@implementation FXTarget
- (void)toggle {
    gPanel.hidden = !gPanel.hidden;
    if (!gPanel.hidden) { clampButton(); layoutPanel(); }
}
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *sv = gBtn.superview;
    CGPoint t = [g translationInView:sv];
    gBtn.center = CGPointMake(gBtn.center.x + t.x, gBtn.center.y + t.y);
    [g setTranslation:CGPointZero inView:sv];
    clampButton();
    layoutPanel();
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setFloat:gBtn.center.x forKey:@"fx2_bx"];
        [d setFloat:gBtn.center.y forKey:@"fx2_by"];
    }
}
- (void)reset {
    for (int i = 0; i < P_COUNT; i++) {
        atomic_store(&gP[i], kDefs[i].def);
        gSliders[i].value = kDefs[i].def;
        gLabels[i].text = labelText(i, kDefs[i].def);
    }
    saveParams();
}
@end
static FXTarget *gTarget;

static void buildUI(void) {
    if (gUIBuilt) return;

    UIWindowScene *scene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            scene = (UIWindowScene *)s;
            if (s.activationState == UISceneActivationStateForegroundActive) break;
        }
    }
    if (!scene) return;

    gUIBuilt = YES;
    gWindow = [[FXWindow alloc] initWithWindowScene:scene];
    gWindow.frame = scene.coordinateSpace.bounds;
    gWindow.windowLevel = UIWindowLevelAlert + 100;
    gWindow.backgroundColor = UIColor.clearColor;
    gVC = [UIViewController new];
    gVC.view.backgroundColor = UIColor.clearColor;
    gWindow.rootViewController = gVC;
    gWindow.hidden = NO;

    gTarget = [FXTarget new];
    gSliders = [NSMutableArray new];
    gLabels = [NSMutableArray new];

    // Bouton FX (déplaçable)
    gBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    gBtn.frame = CGRectMake(0, 0, 48, 48);
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    CGFloat bx = [ud objectForKey:@"fx2_bx"] ? [ud floatForKey:@"fx2_bx"] : 40;
    CGFloat by = [ud objectForKey:@"fx2_by"] ? [ud floatForKey:@"fx2_by"] : 100;
    gBtn.center = CGPointMake(bx, by);
    gBtn.backgroundColor = [UIColor colorWithRed:0.11 green:0.73 blue:0.33 alpha:0.95];
    gBtn.layer.cornerRadius = 24;
    [gBtn setTitle:@"FX" forState:UIControlStateNormal];
    [gBtn setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    gBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [gBtn addTarget:gTarget action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:gTarget action:@selector(pan:)];
    [gBtn addGestureRecognizer:pan];
    [gVC.view addSubview:gBtn];

    // Panel
    CGFloat pw = 300, ph = 480;
    gPanel = [[UIView alloc] initWithFrame:CGRectMake(16, 160, pw, ph)];
    gPanel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.95];
    gPanel.layer.cornerRadius = 16;
    gPanel.clipsToBounds = YES;
    gPanel.hidden = YES;
    [gVC.view addSubview:gPanel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 180, 24)];
    title.text = @"SpotifyFX";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:17];
    [gPanel addSubview:title];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(pw - 67, 8, 51, 31)];
    sw.on = atomic_load(&gActive) != 0;
    sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [sw addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
        atomic_store(&gActive, sw.on ? 1 : 0);
        saveParams();
    }] forControlEvents:UIControlEventValueChanged];
    [gPanel addSubview:sw];

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 48, pw, ph - 48 - 48)];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.showsVerticalScrollIndicator = YES;
    scroll.contentSize = CGSizeMake(pw, 8 + P_COUNT * 62 + 8);
    [gPanel addSubview:scroll];

    for (int i = 0; i < P_COUNT; i++) {
        CGFloat y = 8 + i * 62;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(16, y, pw - 32, 20)];
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        label.text = labelText(i, GP(i));
        [scroll addSubview:label];

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(16, y + 24, pw - 32, 30)];
        slider.minimumValue = kDefs[i].min;
        slider.maximumValue = kDefs[i].max;
        slider.value = GP(i);
        BOOL isDb = !strcmp(kDefs[i].unit, "dB");
        [slider addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
            float v = isDb ? roundf(slider.value * 2.0f) / 2.0f : roundf(slider.value);
            label.text = labelText(i, v);
            atomic_store(&gP[i], v);
            saveParams();
        }] forControlEvents:UIControlEventValueChanged];
        [scroll addSubview:slider];

        [gSliders addObject:slider];
        [gLabels addObject:label];
    }

    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    reset.frame = CGRectMake(16, ph - 42, pw - 32, 34);
    reset.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    [reset setTitle:@"Réinitialiser" forState:UIControlStateNormal];
    [reset addTarget:gTarget action:@selector(reset) forControlEvents:UIControlEventTouchUpInside];
    [gPanel addSubview:reset];

    clampButton();
    FXLog(@"Panel créé");
}

static dispatch_source_t keepTimer;

__attribute__((constructor))
static void init(void) {
    FXLog(@"SpotifyFX chargée (panel v2)");
    for (int i = 0; i < P_COUNT; i++) atomic_store(&gP[i], kDefs[i].def);
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
    dispatch_source_set_timer(keepTimer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, 0);
    dispatch_source_set_event_handler(keepTimer, ^{
        FXLog([NSString stringWithFormat:@"vol=%.1f bass=%.1f treble=%.1f rev=%.0f echo=%.0f active=%d cb=%d peak=%d",
               GP(P_VOL), GP(P_BASS), GP(P_TREBLE), GP(P_REVMIX), GP(P_ECHOMIX),
               atomic_load(&gActive), atomic_load(&cCallback), atomic_exchange(&peakPost, 0)]);
    });
    dispatch_resume(keepTimer);
}
