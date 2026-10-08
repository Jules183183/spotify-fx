#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include "fishhook.h"
#include <stdatomic.h>

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

static atomic_int cRender, cEnqueue, cSetProp, cNewOutput;

static OSStatus (*orig_AudioUnitRender)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32, AudioBufferList *);
static OSStatus my_AudioUnitRender(AudioUnit u, AudioUnitRenderActionFlags *f, const AudioTimeStamp *t, UInt32 bus, UInt32 frames, AudioBufferList *io) {
    atomic_fetch_add(&cRender, 1);
    return orig_AudioUnitRender(u, f, t, bus, frames, io);
}

static OSStatus (*orig_AudioQueueEnqueueBuffer)(AudioQueueRef, AudioQueueBufferRef, UInt32, const AudioStreamPacketDescription *);
static OSStatus my_AudioQueueEnqueueBuffer(AudioQueueRef q, AudioQueueBufferRef b, UInt32 n, const AudioStreamPacketDescription *d) {
    atomic_fetch_add(&cEnqueue, 1);
    return orig_AudioQueueEnqueueBuffer(q, b, n, d);
}

static OSStatus (*orig_AudioUnitSetProperty)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
static OSStatus my_AudioUnitSetProperty(AudioUnit u, AudioUnitPropertyID p, AudioUnitScope s, AudioUnitElement e, const void *d, UInt32 sz) {
    atomic_fetch_add(&cSetProp, 1);
    if (p == kAudioUnitProperty_SetRenderCallback && d && sz >= sizeof(AURenderCallbackStruct)) {
        const AURenderCallbackStruct *cb = (const AURenderCallbackStruct *)d;
        FXLog([NSString stringWithFormat:@"RenderCallback scope=%u elem=%u fn=%p", (unsigned)s, (unsigned)e, cb->inputProc]);
    }
    if (p == kAudioUnitProperty_StreamFormat && d && sz >= sizeof(AudioStreamBasicDescription)) {
        const AudioStreamBasicDescription *f = (const AudioStreamBasicDescription *)d;
        FXLog([NSString stringWithFormat:@"StreamFormat scope=%u rate=%.0f flags=0x%x bits=%u ch=%u fmt=%u",
               (unsigned)s, f->mSampleRate, (unsigned)f->mFormatFlags, (unsigned)f->mBitsPerChannel, (unsigned)f->mChannelsPerFrame, (unsigned)f->mFormatID]);
    }
    return orig_AudioUnitSetProperty(u, p, s, e, d, sz);
}

static OSStatus (*orig_AudioQueueNewOutput)(const AudioStreamBasicDescription *, AudioQueueOutputCallback, void *, CFRunLoopRef, CFStringRef, UInt32, AudioQueueRef *);
static OSStatus my_AudioQueueNewOutput(const AudioStreamBasicDescription *fmt, AudioQueueOutputCallback cb, void *ud, CFRunLoopRef rl, CFStringRef mode, UInt32 flags, AudioQueueRef *out) {
    atomic_fetch_add(&cNewOutput, 1);
    return orig_AudioQueueNewOutput(fmt, cb, ud, rl, mode, flags, out);
}

static dispatch_source_t keepTimer;

__attribute__((constructor))
static void init(void) {
    FXLog(@"SpotifyFX chargée");

    rebind_symbols((struct rebinding[]){
        {"AudioUnitRender", my_AudioUnitRender, (void *)&orig_AudioUnitRender},
        {"AudioQueueEnqueueBuffer", my_AudioQueueEnqueueBuffer, (void *)&orig_AudioQueueEnqueueBuffer},
        {"AudioUnitSetProperty", my_AudioUnitSetProperty, (void *)&orig_AudioUnitSetProperty},
        {"AudioQueueNewOutput", my_AudioQueueNewOutput, (void *)&orig_AudioQueueNewOutput},
    }, 4);

    keepTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(keepTimer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, 0);
    dispatch_source_set_event_handler(keepTimer, ^{
        FXLog([NSString stringWithFormat:@"render=%d enqueue=%d setProp=%d newOutput=%d",
               atomic_load(&cRender), atomic_load(&cEnqueue), atomic_load(&cSetProp), atomic_load(&cNewOutput)]);
    });
    dispatch_resume(keepTimer);
}
