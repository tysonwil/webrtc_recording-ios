/*
 *  Copyright 2015 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "webrtc/api/objc/avfoundationvideocapturer.h"

#include "webrtc/base/bind.h"
#include "webrtc/base/thread.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "webrtc/base/objc/RTCDispatcher.h"
#import "webrtc/base/objc/RTCLogging.h"

#import "webrtc/modules/audio_device/ios/objc/RTCAudioSession.h"

#import "webrtc/modules/audio_device/ios/audio_device_ios.h"


// TODO(tkchin): support other formats.
static NSString* const kDefaultPreset = AVCaptureSessionPreset640x480;
static cricket::VideoFormat const kDefaultFormat =
cricket::VideoFormat(640,
                     480,
                     cricket::VideoFormat::FpsToInterval(30),
                     cricket::FOURCC_NV12);

// This class used to capture frames using AVFoundation APIs on iOS. It is meant
// to be owned by an instance of AVFoundationVideoCapturer. The reason for this
// because other webrtc objects own cricket::VideoCapturer, which is not
// ref counted. To prevent bad behavior we do not expose this class directly.
@interface RTCAVFoundationVideoCapturerInternal : NSObject
<AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, AVAudioRecorderDelegate>

@property(nonatomic, readonly) AVCaptureSession *captureSession;
@property(nonatomic, readonly) BOOL isRunning;
@property(nonatomic, readonly) BOOL canUseBackCamera;
@property(nonatomic, assign) BOOL useBackCamera;  // Defaults to NO.

@property(nonatomic, strong) AVAssetWriter *assetWriter;
@property(nonatomic, strong) AVAssetWriterInput *assetWriterVideoInput;
@property(nonatomic, strong) AVAssetWriterInput *assetWriterAudioInput;

@property (strong, nonatomic) AVAudioRecorder *audioRecorder;
@property (strong, nonatomic) NSURL *soundFileURL;

@property (nonatomic) double audioStarted;
@property (nonatomic) double audioEnded;
@property (nonatomic) double videoStarted;
@property (nonatomic) double videoEnded;

// We keep a pointer back to AVFoundationVideoCapturer to make callbacks on it
// when we receive frames. This is safe because this object should be owned by
// it.
- (instancetype)initWithCapturer:(webrtc::AVFoundationVideoCapturer *)capturer;
- (void)startCaptureAsync;
- (void)stopCaptureAsync;

@end

@implementation RTCAVFoundationVideoCapturerInternal {
    // Keep pointers to inputs for convenience.
    AVCaptureDeviceInput *_frontDeviceInput;
    AVCaptureDeviceInput *_backDeviceInput;
    AVCaptureDeviceInput *_microphone;
    AVCaptureVideoDataOutput *_videoOutput;
    AVCaptureAudioDataOutput *_audioOutput;
    // The cricket::VideoCapturer that owns this class. Should never be NULL.
    webrtc::AVFoundationVideoCapturer *_capturer;
    BOOL _orientationHasChanged;
}

@synthesize captureSession = _captureSession;
@synthesize useBackCamera = _useBackCamera;
@synthesize isRunning = _isRunning;
@synthesize assetWriter = _assetWriter;
@synthesize assetWriterVideoInput = _assetWriterVideoInput;
@synthesize assetWriterAudioInput = _assetWriterAudioInput;
@synthesize audioRecorder = _audioRecorder;
@synthesize soundFileURL = _soundFileURL;
@synthesize audioStarted = _audioStarted;
@synthesize audioEnded = _audioEnded;
@synthesize videoStarted = _videoStarted;
@synthesize videoEnded = _videoEnded;

- (instancetype)initWithCapturer:(webrtc::AVFoundationVideoCapturer *)capturer {
    NSParameterAssert(capturer);
    if (self = [super init]) {
        _capturer = capturer;
        if (![self setupCaptureSession]) {
            return nil;
        }
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        [center addObserver:self
                   selector:@selector(deviceOrientationDidChange:)
                       name:UIDeviceOrientationDidChangeNotification
                     object:nil];
        [center addObserverForName:AVCaptureSessionRuntimeErrorNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification *notification) {
                            NSLog(@"Capture session error: %@", notification.userInfo);
                        }];
    }
    
    
    
    return self;
}

- (void)dealloc {
    [self stopCaptureAsync];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _capturer = nullptr;
}

- (BOOL)canUseBackCamera {
    return _backDeviceInput != nil;
}

- (void)setUseBackCamera:(BOOL)useBackCamera {
    if (_useBackCamera == useBackCamera) {
        return;
    }
    if (!self.canUseBackCamera) {
        RTCLog(@"No rear-facing camera exists or it cannot be used;"
               "not switching.");
        return;
    }
    _useBackCamera = useBackCamera;
    [self updateSessionInput];
}

- (void)startCaptureAsync {
    if (_isRunning) {
        return;
    }
    
    
    NSArray *dirPaths;
    NSString *docsDir;
    
    dirPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    docsDir = dirPaths[0];
    
    NSString *soundFilePath = [docsDir stringByAppendingPathComponent:@"sound.caf"];
    
    _soundFileURL = [NSURL fileURLWithPath:soundFilePath];
    
    
    NSDictionary *recordSettings = [NSDictionary
                                    dictionaryWithObjectsAndKeys:
                                    [NSNumber numberWithInt:AVAudioQualityMin],
                                    AVEncoderAudioQualityKey,
                                    [NSNumber numberWithInt:16],
                                    AVEncoderBitRateKey,
                                    [NSNumber numberWithInt: 2],
                                    AVNumberOfChannelsKey,
                                    [NSNumber numberWithFloat:44100.0],
                                    AVSampleRateKey,
                                    nil];
    
    NSError *error = nil;
    RTCAudioSession *audioSession = [RTCAudioSession sharedInstance];
    [audioSession lockForConfiguration];
    [audioSession setActive:YES error:nil];
    [audioSession setCategory:AVAudioSessionCategoryPlayAndRecord withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker error:&error];
    _audioRecorder = [[AVAudioRecorder alloc] initWithURL:_soundFileURL settings:recordSettings error:&error];
    [audioSession unlockForConfiguration];

    _audioRecorder.delegate = self;
    
    if (error) {
        NSLog(@"error: %@", [error localizedDescription]);
    } else {
        //[_audioRecorder prepareToRecord];
    }
    
    
    
    
    _orientationHasChanged = NO;
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    AVCaptureSession* session = _captureSession;
    [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
                                 block:^{
                                     [session startRunning];
                                     [_audioRecorder record];
                                     _audioStarted = _audioRecorder.deviceCurrentTime;
                                     
                                 }];
    _isRunning = YES;
}

- (void)stopCaptureAsync {
    if (!_isRunning) {
        return;
    }
    [_audioRecorder stop];

    [_videoOutput setSampleBufferDelegate:nil queue:nullptr];
    AVCaptureSession* session = _captureSession;
    [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
                                 block:^{
                                     [session stopRunning];
                                     //[self.assetWriter finishWritingWithCompletionHandler:<#^(void)handler#>]
                                     //[self.assetWriter endSessionAtSourceTime:CMClockGetTime(self.captureSession.masterClock)];
                                     
                                     //[_audioRecorder stop];
                                     
                                     [self.assetWriter finishWritingWithCompletionHandler:^{
                                         NSLog(@"**** WRITING FINISHED ****");
                                         //UISaveVideoAtPathToSavedPhotosAlbum(self.assetWriter.outputURL.path, self, @selector(video:didFinishSavingWithError:contextInfo:), nil);
                                         [self mergeAudioVideo];
                                     }];
                                 }];
    [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
    _isRunning = NO;
}

-(void)mergeAudioVideo {
    AVMutableComposition* mixComposition = [AVMutableComposition composition];
    
    AVURLAsset  *audioAsset = [[AVURLAsset alloc]initWithURL:_soundFileURL options:nil];
    CMTimeRange audio_timeRange = CMTimeRangeMake(kCMTimeZero, audioAsset.duration);
    
    AVURLAsset  *videoAsset = [[AVURLAsset alloc]initWithURL:self.assetWriter.outputURL options:nil];
    //CMTimeRange video_timeRange = CMTimeRangeMake(kCMTimeZero,audioAsset.duration);
    CMTimeRange video_timeRange = CMTimeRangeMake(kCMTimeZero,videoAsset.duration);
    
    float ar = float(audio_timeRange.duration.value) / audio_timeRange.duration.timescale;
    float vr = float(video_timeRange.duration.value) / video_timeRange.duration.timescale;
    
    float dif = vr - ar;
    NSLog(@"duration dif: %f", dif);
    
    float startDif = _videoStarted - _audioStarted;
    NSLog(@"start dif: %f", startDif);
    
    //Now we are creating the first AVMutableCompositionTrack containing our audio and add it to our AVMutableComposition object.
    AVMutableCompositionTrack *b_compositionAudioTrack = [mixComposition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    [b_compositionAudioTrack insertTimeRange:video_timeRange ofTrack:[[audioAsset tracksWithMediaType:AVMediaTypeAudio] objectAtIndex:0] atTime:CMTimeMakeWithSeconds(-1 * startDif, 1000) error:nil];
    

    


    
    //Now we are creating the second AVMutableCompositionTrack containing our video and add it to our AVMutableComposition object.
    AVMutableCompositionTrack *a_compositionVideoTrack = [mixComposition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    [a_compositionVideoTrack insertTimeRange:video_timeRange ofTrack:[[videoAsset tracksWithMediaType:AVMediaTypeVideo] objectAtIndex:0] atTime:kCMTimeZero error:nil];
    
    //decide the path where you want to store the final video created with audio and video merge.
    NSArray *dirPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docsDir = [dirPaths objectAtIndex:0];
    NSString *outputFilePath = [docsDir stringByAppendingPathComponent:[NSString stringWithFormat:@"FinalVideo.mov"]];
    NSURL *outputFileUrl = [NSURL fileURLWithPath:outputFilePath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:outputFilePath])
        [[NSFileManager defaultManager] removeItemAtPath:outputFilePath error:nil];
    
    //Now create an AVAssetExportSession object that will save your final video at specified path.
    AVAssetExportSession* _assetExport = [[AVAssetExportSession alloc] initWithAsset:mixComposition presetName:AVAssetExportPresetHighestQuality];
    _assetExport.outputFileType = @"com.apple.quicktime-movie";
    _assetExport.outputURL = outputFileUrl;
    
    [_assetExport exportAsynchronouslyWithCompletionHandler:
     ^(void ) {
         
         dispatch_async(dispatch_get_main_queue(), ^{
             [self exportDidFinish:_assetExport];
         });
     }
     ];

}

- (void)exportDidFinish:(AVAssetExportSession*)session {
    if(session.status == AVAssetExportSessionStatusCompleted) {
        NSURL *outputURL = session.outputURL;
        UISaveVideoAtPathToSavedPhotosAlbum(outputURL.path, self, @selector(video:didFinishSavingWithError:contextInfo:), nil);
    }
    
}

#pragma mark AVAudioRecorderDelegate

-(void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder
                          successfully:(BOOL)flag
{
}

-(void)audioRecorderEncodeErrorDidOccur:(AVAudioRecorder *)recorder
                                  error:(NSError *)error
{
    NSLog(@"Encode Error occurred");
}

- (void)video:(NSString *) videoPath didFinishSavingWithError: (NSError *) error contextInfo: (void *) contextInfo {
    if (error) {
        NSLog(@"didFinishSavingWithError: %@", error);
    }
}

#pragma mark AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    //NSParameterAssert(captureOutput == _videoOutput);  // This  asserts that the buffer contains video data (and not audio or anything else)
    if (!_isRunning) {
        return;
    }
    
   // AudioDeviceIOS()
    
    //AudioBufferList audio_record_buffer_list_ =
    
//    if (!_audioRecorder.recording) {
//        [_audioRecorder recordAtTime:CMTimeGetSeconds(CMClockGetTime(self.captureSession.masterClock))];
//    }
    
    //RTCAudioSession *audioSession = [RTCAudioSession sharedInstance];
    //NSLog(@"%@", audioSession.category);
    
    
    
//    [audioSession lockForConfiguration];
//    [audioSession setActive:YES error:nil];
//    [audioSession unlockForConfiguration];
    
    
    
        if (captureOutput == _videoOutput ) {
            if (self.assetWriterVideoInput.readyForMoreMediaData) {
                if (!_audioRecorder.recording) {
                    //[_audioRecorder record];
                }
                BOOL t = [self.assetWriterVideoInput appendSampleBuffer:sampleBuffer];
                if (t) { NSLog(@"appended VIDEO ");}
                if (_audioRecorder.recording) { NSLog(@"audio recording");}
            }
        } else if (captureOutput == _audioOutput) {
            if (self.assetWriterAudioInput.readyForMoreMediaData) {
                BOOL a = [self.assetWriterAudioInput appendSampleBuffer:sampleBuffer];
                if (a) { NSLog(@"appended AUDIO ");}
            }
        }
    
//    RTCAudioSession *session = [RTCAudioSession sharedInstance];
//    NSInteger d = session.inputNumberOfChannels;
//    NSLog(@"%f",double(d));
    
    _capturer->CaptureSampleBuffer(sampleBuffer);
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
  didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    
    CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sampleBuffer, kCMAttachmentMode_ShouldPropagate);
    if (attachments) {
        //k
    }
    
    NSLog(@"Dropped sample buffer: %@", kCMSampleBufferAttachmentKey_DroppedFrameReason);
    
    //NSLog(@"Dropped sample buffer.");
}

#pragma mark - Private

- (BOOL)setupCaptureSession {
    _captureSession = [[AVCaptureSession alloc] init];
#if defined(__IPHONE_7_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_7_0
    NSString *version = [[UIDevice currentDevice] systemVersion];
    if ([version integerValue] >= 7) {
        _captureSession.usesApplicationAudioSession = NO;
    }
#endif
    if (![_captureSession canSetSessionPreset:kDefaultPreset]) {
        NSLog(@"Default video capture preset unsupported.");
        return NO;
    }
    _captureSession.sessionPreset = kDefaultPreset;
    
    // Make the capturer output NV12. Ideally we want I420 but that's not
    // currently supported on iPhone / iPad.
    _videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    _videoOutput.videoSettings = @{
                                   (NSString *)kCVPixelBufferPixelFormatTypeKey :
                                       @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                                   };
    _videoOutput.alwaysDiscardsLateVideoFrames = NO;
    [_videoOutput setSampleBufferDelegate:self
                                    queue:dispatch_get_main_queue()];
    if (![_captureSession canAddOutput:_videoOutput]) {
        NSLog(@"Default video capture output unsupported.");
        return NO;
    }
    [_captureSession addOutput:_videoOutput];
    
    // Audio output setup
    _audioOutput = [[AVCaptureAudioDataOutput alloc] init];
    if (![_captureSession canAddOutput:_audioOutput]) {
        NSLog(@"Default audio capture output unsupported.");
        return NO;
    }
    //[_audioOutput setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
    [_captureSession addOutput:_audioOutput];
    
    // Find the capture devices.
    AVCaptureDevice *frontCaptureDevice = nil;
    AVCaptureDevice *backCaptureDevice = nil;
    for (AVCaptureDevice *captureDevice in
         [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
        if (captureDevice.position == AVCaptureDevicePositionBack) {
            backCaptureDevice = captureDevice;
        }
        if (captureDevice.position == AVCaptureDevicePositionFront) {
            frontCaptureDevice = captureDevice;
        }
    }
    if (!frontCaptureDevice) {
        RTCLog(@"Failed to get front capture device.");
        return NO;
    }
    if (!backCaptureDevice) {
        RTCLog(@"Failed to get back capture device");
        // Don't return NO here because devices exist (16GB 5th generation iPod
        // Touch) that don't have a rear-facing camera.
    }
    
    AVCaptureDevice *microphone = nil;
    for (AVCaptureDevice *captureDevice in [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio]) {
        microphone = captureDevice;
    }
    if (!microphone) {
        NSLog(@"Failed to get microphone");
        RTCLog(@"Failed to get microphone");
    }
    
    // Set up the session inputs.
    NSError *error = nil;
    _frontDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:frontCaptureDevice
                                                              error:&error];
    if (!_frontDeviceInput) {
        NSLog(@"Failed to get capture device input: %@",
              error.localizedDescription);
        return NO;
    }
    if (backCaptureDevice) {
        error = nil;
        _backDeviceInput =
        [AVCaptureDeviceInput deviceInputWithDevice:backCaptureDevice
                                              error:&error];
        if (error) {
            RTCLog(@"Failed to get capture device input: %@",
                   error.localizedDescription);
            _backDeviceInput = nil;
        }
    }
    
    _microphone = [AVCaptureDeviceInput deviceInputWithDevice:microphone
                                                        error:&error];
    if (!_microphone) {
        NSLog(@"Failed to get capture device input: %@", error.localizedDescription);
        return NO;
    }
    
    // Add the inputs.
    if (![_captureSession canAddInput:_frontDeviceInput] ||
        (_backDeviceInput && ![_captureSession canAddInput:_backDeviceInput])) {
        NSLog(@"Session does not support capture inputs.");
        return NO;
    }
    
//    if (![_captureSession canAddInput:_microphone]) {
//        NSLog(@"Session does not support microphone input.");
//        return NO;
//    
//    } else {
//        [_captureSession addInput:_microphone];   // TODO: THIS IS THE BUG HERE. IF MICROPHONE IS ADDED TO THE CAPTURE SESSION, NOTHING IS SENT THROUGH RTC
//    }

    [self updateSessionInput];
    
    // Setup local video buffer
    NSDictionary *videoCompressionProps = [NSDictionary dictionaryWithObjectsAndKeys:
                                           [NSNumber numberWithInt:500000], AVVideoAverageBitRateKey,
                                           [NSNumber numberWithInt:90],AVVideoMaxKeyFrameIntervalKey,
                                           AVVideoProfileLevelH264Baseline41, AVVideoProfileLevelKey,
                                           nil];
    
    NSDictionary *videoSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                   AVVideoCodecH264, AVVideoCodecKey,
                                   [NSNumber numberWithInt:375], AVVideoWidthKey,
                                   [NSNumber numberWithInt:667], AVVideoHeightKey,
                                   videoCompressionProps, AVVideoCompressionPropertiesKey,
                                   nil];
    
    self.assetWriterVideoInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
    self.assetWriterVideoInput.expectsMediaDataInRealTime = YES;
    
    // Setup local audio buffer
    NSDictionary *audioSettings = [NSDictionary dictionaryWithObjectsAndKeys:
                                   [NSNumber numberWithInt:kAudioFormatMPEG4AAC], AVFormatIDKey,
                                   [NSNumber numberWithInt:2], AVNumberOfChannelsKey,
                                   [NSNumber numberWithDouble:44100.0], AVSampleRateKey,
                                   nil];
    
    self.assetWriterAudioInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
    self.assetWriterAudioInput.expectsMediaDataInRealTime = YES;
    
    NSURL *outputURL = [self uniqueVideoURL];
    
    NSError *outError;
    self.assetWriter = [AVAssetWriter assetWriterWithURL:outputURL fileType:AVFileTypeMPEG4 error:&outError];
    [self.assetWriter addInput:self.assetWriterVideoInput];
    [self.assetWriter addInput:self.assetWriterAudioInput];
    [self.assetWriter startWriting];
    CMTime videoStart = CMClockGetTime(self.captureSession.masterClock);
    
    self.videoStarted = double(videoStart.value) / videoStart.timescale;
    
    CFAbsoluteTime k = CFAbsoluteTimeGetCurrent();
    NSLog(@"%f",k);
    
    [self.assetWriter startSessionAtSourceTime:videoStart];
    
    
    return YES;
}

- (NSURL *)uniqueVideoURL {
    NSString *uniqueID = [NSUUID UUID].UUIDString;
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray<NSURL *> *urls = [fileManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
    if (urls[0] != nil) {
        NSURL *documentDirectory = urls[0];
        NSString *localVideoName = [uniqueID stringByAppendingString:@".mp4"];
        return [documentDirectory URLByAppendingPathComponent:localVideoName];
    } else {
        NSLog(@"document directory error");
        return nil; //TODO: fix
    }
}

- (void)deviceOrientationDidChange:(NSNotification *)notification {
    _orientationHasChanged = YES;
    [self updateOrientation];
}

- (void)updateOrientation {
    AVCaptureConnection *connection =
    [_videoOutput connectionWithMediaType:AVMediaTypeVideo];
    if (!connection.supportsVideoOrientation) {
        // TODO(tkchin): set rotation bit on frames.
        return;
    }
    AVCaptureVideoOrientation orientation = AVCaptureVideoOrientationPortrait;
    switch ([UIDevice currentDevice].orientation) {
        case UIDeviceOrientationPortrait:
            orientation = AVCaptureVideoOrientationPortrait;
            break;
        case UIDeviceOrientationPortraitUpsideDown:
            orientation = AVCaptureVideoOrientationPortraitUpsideDown;
            break;
        case UIDeviceOrientationLandscapeLeft:
            orientation = AVCaptureVideoOrientationLandscapeRight;
            break;
        case UIDeviceOrientationLandscapeRight:
            orientation = AVCaptureVideoOrientationLandscapeLeft;
            break;
        case UIDeviceOrientationFaceUp:
        case UIDeviceOrientationFaceDown:
        case UIDeviceOrientationUnknown:
            if (!_orientationHasChanged) {
                connection.videoOrientation = orientation;
            }
            return;
    }
    connection.videoOrientation = orientation;
}

- (void)updateSessionInput {
    // Update the current session input to match what's stored in _useBackCamera.
    [_captureSession beginConfiguration];
    AVCaptureDeviceInput *oldInput = _backDeviceInput;
    AVCaptureDeviceInput *newInput = _frontDeviceInput;
    if (_useBackCamera) {
        oldInput = _frontDeviceInput;
        newInput = _backDeviceInput;
    }
    // Ok to remove this even if it's not attached. Will be no-op.
    [_captureSession removeInput:oldInput];
    [_captureSession addInput:newInput];
    [self updateOrientation];
    [_captureSession commitConfiguration];
}

@end

namespace webrtc {
    
    AVFoundationVideoCapturer::AVFoundationVideoCapturer()
    : _capturer(nil), _startThread(nullptr) {
        // Set our supported formats. This matches kDefaultPreset.
        std::vector<cricket::VideoFormat> supportedFormats;
        supportedFormats.push_back(cricket::VideoFormat(kDefaultFormat));
        SetSupportedFormats(supportedFormats);
        _capturer =
        [[RTCAVFoundationVideoCapturerInternal alloc] initWithCapturer:this];
    }
    
    AVFoundationVideoCapturer::~AVFoundationVideoCapturer() {
        _capturer = nil;
    }
    
    cricket::CaptureState AVFoundationVideoCapturer::Start(
                                                           const cricket::VideoFormat& format) {
        if (!_capturer) {
            LOG(LS_ERROR) << "Failed to create AVFoundation capturer.";
            return cricket::CaptureState::CS_FAILED;
        }
        if (_capturer.isRunning) {
            LOG(LS_ERROR) << "The capturer is already running.";
            return cricket::CaptureState::CS_FAILED;
        }
        if (format != kDefaultFormat) {
            LOG(LS_ERROR) << "Unsupported format provided.";
            return cricket::CaptureState::CS_FAILED;
        }
        
        // Keep track of which thread capture started on. This is the thread that
        // frames need to be sent to.
        RTC_DCHECK(!_startThread);
        _startThread = rtc::Thread::Current();
        
        SetCaptureFormat(&format);
        // This isn't super accurate because it takes a while for the AVCaptureSession
        // to spin up, and this call returns async.
        // TODO(tkchin): make this better.
        [_capturer startCaptureAsync];
        SetCaptureState(cricket::CaptureState::CS_RUNNING);
        
        return cricket::CaptureState::CS_STARTING;
    }
    
    void AVFoundationVideoCapturer::Stop() {
        [_capturer stopCaptureAsync];
        SetCaptureFormat(NULL);
        _startThread = nullptr;
    }
    
    bool AVFoundationVideoCapturer::IsRunning() {
        return _capturer.isRunning;
    }
    
    AVCaptureSession* AVFoundationVideoCapturer::GetCaptureSession() {
        return _capturer.captureSession;
    }
    
    bool AVFoundationVideoCapturer::CanUseBackCamera() const {
        return _capturer.canUseBackCamera;
    }
    
    void AVFoundationVideoCapturer::SetUseBackCamera(bool useBackCamera) {
        _capturer.useBackCamera = useBackCamera;
    }
    
    bool AVFoundationVideoCapturer::GetUseBackCamera() const {
        return _capturer.useBackCamera;
    }
    
    void AVFoundationVideoCapturer::CaptureSampleBuffer(CMSampleBufferRef sampleBuffer) {
        if (CMSampleBufferGetNumSamples(sampleBuffer) != 1 ||
            !CMSampleBufferIsValid(sampleBuffer) ||
            !CMSampleBufferDataIsReady(sampleBuffer)) {
            return;
        }
        
        CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (imageBuffer == NULL) {
            return;
        }
        
        // Base address must be unlocked to access frame data.
        CVOptionFlags lockFlags = kCVPixelBufferLock_ReadOnly;
        CVReturn ret = CVPixelBufferLockBaseAddress(imageBuffer, lockFlags);
        if (ret != kCVReturnSuccess) {
            return;
        }
        
        static size_t const kYPlaneIndex = 0;
        static size_t const kUVPlaneIndex = 1;
        uint8_t *yPlaneAddress =
        (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, kYPlaneIndex);
        size_t yPlaneHeight =
        CVPixelBufferGetHeightOfPlane(imageBuffer, kYPlaneIndex);
        size_t yPlaneWidth =
        CVPixelBufferGetWidthOfPlane(imageBuffer, kYPlaneIndex);
        size_t yPlaneBytesPerRow =
        CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, kYPlaneIndex);
        size_t uvPlaneHeight =
        CVPixelBufferGetHeightOfPlane(imageBuffer, kUVPlaneIndex);
        size_t uvPlaneBytesPerRow =
        CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, kUVPlaneIndex);
        size_t frameSize =
        yPlaneBytesPerRow * yPlaneHeight + uvPlaneBytesPerRow * uvPlaneHeight;
        
        // Sanity check assumption that planar bytes are contiguous.
        uint8_t *uvPlaneAddress =
        (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, kUVPlaneIndex);
        RTC_DCHECK(
                   uvPlaneAddress == yPlaneAddress + yPlaneHeight * yPlaneBytesPerRow);
        
        // Stuff data into a cricket::CapturedFrame.
        int64_t currentTime = rtc::TimeNanos();
        cricket::CapturedFrame frame;
        frame.width = yPlaneWidth;
        frame.height = yPlaneHeight;
        frame.pixel_width = 1;
        frame.pixel_height = 1;
        frame.fourcc = static_cast<uint32_t>(cricket::FOURCC_NV12);
        frame.time_stamp = currentTime;
        frame.data = yPlaneAddress;
        frame.data_size = frameSize;
        
        
        if (_startThread->IsCurrent()) {
            SignalFrameCaptured(this, &frame);
        } else {
            _startThread->Invoke<void>(
                                       rtc::Bind(&AVFoundationVideoCapturer::SignalFrameCapturedOnStartThread,
                                                 this, &frame));
        }
        CVPixelBufferUnlockBaseAddress(imageBuffer, lockFlags);
    }
    
    void AVFoundationVideoCapturer::SignalFrameCapturedOnStartThread(
                                                                     const cricket::CapturedFrame *frame) {
        RTC_DCHECK(_startThread->IsCurrent());
        // This will call a superclass method that will perform the frame conversion
        // to I420.
        SignalFrameCaptured(this, frame);
    }
    
}  // namespace webrtc
