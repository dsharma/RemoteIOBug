//
//  MicrophoneOutput.swift
//  Camera4S-Swift
//
//  Created by Deepak Sharma on 4/26/17.
//  Copyright © 2017 Deepak Sharma. All rights reserved.
//

import Foundation
import AVFoundation
import AudioToolbox
import CoreAudioKit
import CoreMedia

typealias sampleType = Int16
let       sampleWordSize = MemoryLayout<sampleType>.stride
let kInputBus = 1
let kOutputBus = 0

let audioMonitoringNotification = "AudioMonitoringNotification"
let audioGainAvailableNotification = "audioGainAvailableNotification"
let newAudioInputNotification = "newAudioInputNotification"

public protocol MicrophoneOutputDelegate:NSObjectProtocol {
    func audioOutput(micOut:MicrophoneOutput, didOutputSampleBuffer sampleBuffer:CMSampleBuffer)
}

func lpcmFormatDescription(_ this: MicrophoneOutput) -> AudioStreamBasicDescription {
    var format:AudioStreamBasicDescription = AudioStreamBasicDescription()
    
    let wordsize = sampleWordSize
    
    format.mFramesPerPacket = 1
    format.mBytesPerFrame =  UInt32(wordsize)
    format.mChannelsPerFrame = UInt32(this.numChannels)
    format.mBitsPerChannel = UInt32(wordsize * 8)
    format.mBytesPerPacket = UInt32(wordsize)
    format.mFormatID = kAudioFormatLinearPCM
    
    //  format.mFormatFlags = kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked | kAudioFormatFlagIsFloat |kAudioFormatFlagIsNonInterleaved;
    format.mFormatFlags = kAudioFormatFlagIsPacked | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsNonInterleaved
    
    format.mSampleRate = this.sampleRate
    
    return format
}


public class MicrophoneOutput: NSObject {
    
    private(set) public var audioUnit:AudioComponentInstance?
    private(set) public var sampleBufferQueue:DispatchQueue?
    public weak var sampleBufferDelegate:MicrophoneOutputDelegate?
    public var preferredAutoMicrophoneOrientation:String?

    var unitRunning = false
    var unitCreated = false
    //   BOOL unitHasBeenDeallocated;
    
    private var interrupted = false
    
    public var formatDescription:CMFormatDescription?
    
 //   private var samplesOne:UnsafeMutablePointer<sampleType>
 //   private var samplesTwo:UnsafeMutablePointer<sampleType>
    private var numFrames:Int = 0
    
    private(set) public var sampleRate:Double = 44100
    private(set) public var numChannels = 2
    private(set) public var numChanncelsInAudioSession = 0 // numChannels may be configured differently than actual channels in session

    public   var active:Bool = false
    private  var newSampleRate:Double = 0
    
    private(set) public var audioBufferList:UnsafeMutableAudioBufferListPointer
    
    private let  bufferLength  = 16*16*1024
    private let  maxFrames     = 4096 // Theoretical max for any RIO
    
   // let audioSession = AVAudioSession.sharedInstance()
    
    init?(delegate:MicrophoneOutputDelegate?, callbackQueue:DispatchQueue?) {
        
        let options:AVAudioSessionCategoryOptions = .mixWithOthers
        
        do {
            try AVAudioSession.sharedInstance().setCategory(AVAudioSessionCategoryPlayAndRecord, with: options)
        } catch {
            NSLog("Could not set audio session category")
        }
        
        self.sampleBufferDelegate = delegate
        self.sampleBufferQueue = callbackQueue
        
       // samplesOne = UnsafeMutablePointer<sampleType>.allocate(capacity: maxFrames)
       // samplesTwo = UnsafeMutablePointer<sampleType>.allocate(capacity: maxFrames)
        
        audioBufferList = AudioBufferList.allocate(maximumBuffers: 2)
        
        let audioBuffersPointer = audioBufferList.unsafeMutablePointer
        
        let buffers = UnsafeBufferPointer<AudioBuffer>(start: &audioBuffersPointer.pointee.mBuffers,
                                                       count: Int(audioBuffersPointer.pointee.mNumberBuffers))
        
        
        for buf in buffers {
            var buffer = buf
            buffer.mData = UnsafeMutableRawPointer.allocate(byteCount: maxFrames*sampleWordSize, alignment: sampleWordSize)
        }
        
        super.init()
        
        setupAudioSession()
        createOutputUnit()
       
        if !startIOUnit() {
            NSLog("Unable to start IO Unit after creation")
        }
 
    }
    
    deinit {
      //  free(samplesOne)
      //  free(samplesTwo)
        let audioBuffersPointer = audioBufferList.unsafeMutablePointer
        let buffers = UnsafeBufferPointer<AudioBuffer>(start: &audioBuffersPointer.pointee.mBuffers,
                                                       count: Int(audioBuffersPointer.pointee.mNumberBuffers))
        
        for buf in buffers {
           // buf.mData?.deallocate(bytes: maxFrames*sampleWordSize, alignedTo: sampleWordSize)
            buf.mData?.deallocate()
        }
        
        audioBufferList.unsafeMutablePointer.deallocate()
        
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVAudioSessionRouteChange, object: AVAudioSession.sharedInstance())
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVAudioSessionInterruption, object: AVAudioSession.sharedInstance())
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.AVAudioSessionMediaServicesWereReset, object: AVAudioSession.sharedInstance())
        
    }
    
    private func setupAudioSession() {
        
        let audioSession = AVAudioSession.sharedInstance()
        
        do {
            try audioSession.setActive(false)
            try audioSession.setPreferredSampleRate(Double(sampleRate))
        } catch {
            NSLog("Unable to deactivate Audio session")
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange), name: NSNotification.Name.AVAudioSessionRouteChange, object: audioSession)
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: NSNotification.Name.AVAudioSessionInterruption, object: audioSession)
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleMediaServicesReset), name: NSNotification.Name.AVAudioSessionMediaServicesWereReset, object: audioSession)
        
        do {
            try audioSession.setActive(true)
        } catch {
            NSLog("Unable to active AudioSession")
        }
        
        /*
         [[AVAudioSession sharedInstance] addObserver:self forKeyPath:(id)kInputItemsKey options:NSKeyValueObservingOptionNew context:&InputItemsAvailableContext];
         
         */
        
        sampleRate = audioSession.sampleRate
        newSampleRate = audioSession.sampleRate
        numChanncelsInAudioSession = audioSession.inputNumberOfChannels
    }
    
    @objc public func handleRouteChange( note:Notification) {
        NSLog("Handling route change \(note)")
        if let userInfo = (note as NSNotification).userInfo {
            _ = userInfo[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            
            let reason = AVAudioSessionRouteChangeReason(rawValue: userInfo[AVAudioSessionRouteChangeReasonKey] as! UInt)!
            _ = AVAudioSession.sharedInstance().availableInputs
            
            switch reason {
            case .unknown:
                NSLog("     Unknown")
                break
                
            case .newDeviceAvailable:
                NSLog("     NewDeviceAvailable")
                break
                
            case .oldDeviceUnavailable:
                NSLog("     OldDeviceUnavailable")
                break
                
            case .override:
                NSLog("     Override")
                break
                
            case .categoryChange:
                NSLog("     CategoryChange")
                break
                
            case .wakeFromSleep:
                NSLog("     WakeFromSleep")
                break
                
            case .noSuitableRouteForCategory:
                NSLog("     NoSuitableRouteForCategory")
                break
                
            case .routeConfigurationChange:
                NSLog("     AVAudioSessionRouteChangeReasonRouteConfigurationChange")
                break
            }
            
            
            let inputAvailable = AVAudioSession.sharedInstance().isInputAvailable
            
            let currentRoute = AVAudioSession.sharedInstance().currentRoute
            
            let inputs = currentRoute.inputs
            let outputs = currentRoute.outputs
            
            if interrupted {
                return
            }
            
            _ = outputs.count > 0 ? outputs : inputs
            
            
            if self.active {
                if !startIOUnit() {
                    NSLog("Failed starting IO Unit")
                }
            }
            
            if inputAvailable {
                numChanncelsInAudioSession = AVAudioSession.sharedInstance().inputNumberOfChannels
            }
        
            NSLog("Handled route change")
        }
        
    }
    
    @objc public func handleMediaServicesReset( note:NSNotification) {
        usleep(25000)
        
        setupAudioSession()
        createOutputUnit()
        
        if !startIOUnit() {
            NSLog("Failed starting IO Unit after reset")
        }
    }
   
    
    @objc public func handleInterruption( note:Notification) {
        
        let theInterruptionType = (note as NSNotification).userInfo![AVAudioSessionInterruptionTypeKey] as! UInt
            
        
        NSLog("Session interrupted > --- %@ ---\n", theInterruptionType == AVAudioSessionInterruptionType.began.rawValue ? "Begin Interruption" : "End Interruption")
        
        if (theInterruptionType == AVAudioSessionInterruptionType.began.rawValue) {
            stopIOUnit()
        }
        
        if (theInterruptionType == AVAudioSessionInterruptionType.ended.rawValue) {
            // make sure to activate the session
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                numChanncelsInAudioSession = AVAudioSession.sharedInstance().inputNumberOfChannels
            } catch {
                NSLog("Unable to activate Audio Session after Interruption")
            }
            if !startIOUnit() {
               NSLog("Unable to start Audio Unit")
            }
        }
    }
    
    
    public func setAudio( enabled:Bool ) {
        let audioSession = AVAudioSession.sharedInstance()
        
        if enabled {
            do {
                try audioSession.setPreferredSampleRate(Double(44100))
                try audioSession.setActive(true)
            } catch {
                NSLog("Can not activate audio session in setAudio \(enabled)")
            }
            self.active = true
            
            if !startIOUnit() {
                NSLog("Can not enable IOUnit")
            }
        } else {
            self.active = false
        }
    }
    
    private func stopIOUnit() {
        let err = AudioOutputUnitStop(audioUnit!)
        
        if err != noErr {
            NSLog("couldn't stop AURemoteIO: \(err)")
        }
    }
    
    
    public func createOutputUnit() {
        
        let audioSession = AVAudioSession.sharedInstance()
        let currentRoute = audioSession.currentRoute
        let inputs = currentRoute.inputs
        let outputs = currentRoute.outputs
        
        let paths = outputs.count > 0 ? outputs : inputs
        
        let newRouteString = paths[0].portType
        
        NSLog("Inputs = \(inputs), Outputs = \(newRouteString)")
        
        
     //   sampleRate = audioSession.sampleRate
        
        var desc:AudioComponentDescription = AudioComponentDescription()
        desc.componentType = kAudioUnitType_Output
        desc.componentSubType = kAudioUnitSubType_RemoteIO
        desc.componentFlags = 0
        desc.componentFlagsMask = 0
        desc.componentManufacturer = kAudioUnitManufacturer_Apple
        
        let inputComponent = AudioComponentFindNext(nil, &desc)
        var status = AudioComponentInstanceNew(inputComponent!, &audioUnit)
        
        if status != noErr {
            NSLog("Failed creating audio unit, \(status)")
            
            if audioUnit != nil {
                AudioComponentInstanceDispose(audioUnit!)
            }
            
            return
        }
        
        // Enable IO for recording
        var one: UInt32 = 1
        status = AudioUnitSetProperty(audioUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, UInt32(MemoryLayout<UInt32>.stride))
        
        one = 0;
        
        if status != noErr {
            NSLog("Could not enable input on AURemoteIO,  \(status)")
        }
        
        status = AudioUnitSetProperty(audioUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, UInt32(MemoryLayout<UInt32>.stride));
        
        if status != noErr {
            NSLog("Could not enable output on AURemoteIO,  \(status)")
        }
        
        // Describe format
        var audioFormat = lpcmFormatDescription(self)
        
        // Apply format
        status = AudioUnitSetProperty(audioUnit!,
                                     kAudioUnitProperty_StreamFormat,
                                     kAudioUnitScope_Output,
                                     AudioUnitElement(kInputBus),
                                     &audioFormat,
                                     UInt32(MemoryLayout<AudioStreamBasicDescription>.stride))
        
        if status != noErr {
            NSLog("kAudioUnitProperty_StreamFormat On Output,  \(status)")
        }
        
        status = AudioUnitSetProperty(audioUnit!,
                                     kAudioUnitProperty_StreamFormat,
                                     kAudioUnitScope_Input,
                                     AudioUnitElement(kOutputBus),
                                     &audioFormat,
                                     UInt32(MemoryLayout<AudioStreamBasicDescription>.stride))
        
        if status != noErr {
            NSLog("kAudioUnitProperty_StreamFormat On Input,  \(status)")
        }
        
        // Set the MaximumFramesPerSlice property. This property is used to describe to an audio unit the maximum number
        // of samples it will be asked to produce on any single given call to AudioUnitRender
        var maxFramesPerSlice:UInt32 = 4096
        status = AudioUnitSetProperty(audioUnit!, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFramesPerSlice, UInt32(MemoryLayout<UInt32>.stride))
        
        if status != noErr {
            NSLog("couldn't set max frames per slice on AURemoteIO,  \(status)")
        }
        
        // Get the property value back from AURemoteIO. We are going to use this value to allocate buffers accordingly
        var propSize:UInt32 = UInt32(MemoryLayout<UInt32>.stride)
        AudioUnitGetProperty(audioUnit!, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFramesPerSlice, &propSize)
        
        if status != noErr {
            NSLog("couldn't get max frames per slice on AURemoteIO,  \(status)")
        }

        
        NSLog("Audio Unit Init Done")
        
        
        var flag:UInt32 = 0
        
        status = AudioUnitSetProperty(audioUnit!,
                                     kAudioOutputUnitProperty_EnableIO,
                                     kAudioUnitScope_Output,
                                     AudioUnitElement(kOutputBus),
                                     &flag,
                                     UInt32(MemoryLayout<UInt32>.stride))
        
        if status != noErr {
            NSLog("kAudioOutputUnitProperty_EnableIO, Unable to enable/disable playback,\(flag), \(status)")
        }
    
        
        var callbackStruct:AURenderCallbackStruct = AURenderCallbackStruct(inputProc: recordingCallback,
                                                                           inputProcRefCon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        
        status = AudioUnitSetProperty(audioUnit!,
                                      kAudioOutputUnitProperty_SetInputCallback,
                                      kAudioUnitScope_Global,
                                      AudioUnitElement(kInputBus),
                                      &callbackStruct,
                                      UInt32(MemoryLayout<AURenderCallbackStruct>.stride))
        
       // CheckError(AudioUnitInitialize(mAudioUnit), "AudioUnitInitialize");
        
    }

    
    public func startIOUnit() -> Bool {
        
        let err = AudioOutputUnitStart(audioUnit!)
        if err != noErr {
            NSLog("couldn't start AURemoteIO \(err)")
        }
        else {
            NSLog("started AURemoteIO")
        }
        
        return (err == noErr)
    }
}

func recordingCallback(inRefCon:UnsafeMutableRawPointer,
                       ioActionFlags:UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                       inTimeStamp:UnsafePointer<AudioTimeStamp>,
                       inBusNumber:UInt32,
                       inNumberFrames:UInt32,
                       ioData:UnsafeMutablePointer<AudioBufferList>?) -> OSStatus
{
    let controller = unsafeBitCast(inRefCon, to: MicrophoneOutput.self) // inRefCon.assumingMemoryBound(to: MicrophoneOutput.self)
    
    if !controller.active {
        return noErr
    }
    
    let listPtr = controller.audioBufferList.unsafeMutablePointer
    
    let buffers = UnsafeBufferPointer<AudioBuffer>(start: &listPtr.pointee.mBuffers, count: Int(listPtr.pointee.mNumberBuffers))
    
    for var buf in buffers {
        buf.mDataByteSize = inNumberFrames * UInt32(sampleWordSize)
    }
    
    let status = AudioUnitRender(controller.audioUnit!, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, listPtr)
    
    if noErr != status {
        NSLog("Error \(status), \(inNumberFrames)");
      //  fatalError("Render status \(status)")
         return status;
    } else {
        NSLog("No error \(inNumberFrames)")
    }
    
    if controller.numChannels > controller.numChanncelsInAudioSession {
        memcpy(buffers[1].mData, buffers[0].mData, Int(buffers[1].mDataByteSize));
    }
    
    return noErr;
}



