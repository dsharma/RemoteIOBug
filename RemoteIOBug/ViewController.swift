//
//  ViewController.swift
//  RemoteIOBug
//
//  Created by Deepak Sharma on 8/29/18.
//  Copyright © 2018 Deepak Sharma. All rights reserved.
//

import UIKit
import CoreAudio
import AVFoundation

class ViewController: UIViewController {
    
     static var micOut:MicrophoneOutput? = MicrophoneOutput(delegate: nil, callbackQueue: DispatchQueue(label: "com.capturePipeline.micOutput"))

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        ViewController.micOut?.active = true
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(AVAudioSessionCategoryPlayAndRecord, with: .mixWithOthers)
            
            ViewController.micOut?.active = true
            ViewController.micOut?.setAudio(enabled: true)
        } catch {
            NSLog("Unable to set session category to playback")
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }


}

