# RemoteIOBug To reproduce the AudioUnitRender() errors on an iOS device running iOS 11, do the following:

i. Put a breakpoint in the second line of viewDidLoad method, i.e.

            ViewController.micOut?.active = true
            
ii. Launch the app in XCode and immediately quit by pressing the home button/notch. The breakpoint should get hit when the app is in the background.

iii. Bring the app from background to foreground. Now you should see every alternate frame with length 1115 getting render errors.
            
