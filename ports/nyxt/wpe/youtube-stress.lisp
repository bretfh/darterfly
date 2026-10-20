(in-package #:darterfly/test)

;; Deliberately use the ordinary installed browser and real WindowServer HID.
;; JavaScript selects a reproducible quality/seek and observes player state;
;; it does not supply frames or bypass the browser's network/media pipeline.
(defun nyxt-youtube-stress (c)
  (labels
      ((evaluate (form)
         (nyxt-app-ask c (format nil "(nyxt-eval *nyxt-app* ~s)" form) 45))
       (js (script)
         (evaluate (format nil
           "(nyxt:ffi-buffer-evaluate-javascript (nyxt:current-buffer) ~s)"
           script)))
       (until-js (script &optional (seconds 60))
         (nyxt-app-until c (format nil
           "(nyxt:ffi-buffer-evaluate-javascript (nyxt:current-buffer) ~s)"
           script) seconds))
       (click (x y)
         (image:pointer x y t) (sleep .1) (image:pointer x y nil))
       (resize (old-width old-height width height)
         (image:pointer (+ 78 old-width) (+ 78 old-height) t)
         (sleep .15)
         (image:pointer (+ 78 width) (+ 78 height) t)
         (sleep .15)
         (image:pointer (+ 78 width) (+ 78 height) nil)
         (evaluate "(let ((w (nyxt:current-window))) (list :width (nyxt/renderer/wpe::native-width w) :height (nyxt/renderer/wpe::native-height w)))")
         (nyxt-app-until c (format nil
           "(let ((w (nyxt:current-window))) (and (<= (abs (- ~d (nyxt/renderer/wpe::native-width w))) 2) (<= (abs (- ~d (nyxt/renderer/wpe::native-height w))) 2)))"
           width height) 30))
       (snapshot (label)
         (format t "~&[YOUTUBE STRESS ~a]~%" label)
         (js "(()=>{let v=document.querySelector('video'),p=document.querySelector('#movie_player'),q=v?.getVideoPlaybackQuality();return JSON.stringify({url:location.href,title:document.title,ready:document.readyState,state:p?.getPlayerState?.(),quality:p?.getPlaybackQuality?.(),available:p?.getAvailableQualityLevels?.(),time:v?.currentTime,duration:v?.duration,paused:v?.paused,width:v?.videoWidth,height:v?.videoHeight,readyState:v?.readyState,network:v?.networkState,total:q?.totalVideoFrames,dropped:q?.droppedVideoFrames,error:v?.error&&{code:v.error.code,message:v.error.message},callbacks:window.darterVideoFrames,lastFrameTime:window.darterLastFrame,stats:(()=>{let s=p?.getStatsForNerds?.();return s&&{codecs:s.codecs,resolution:s.resolution,buffer:s.buffer_health_seconds,bandwidth:s.bandwidth_kbps,frames:s.dims_and_frames}})()})})()")))
    (unwind-protect
      (progn
        (js "window.darterPreviousDocument=true;true")
        (evaluate (format nil
          "(nyxt:ffi-buffer-load (nyxt:current-buffer) (quri:uri ~s))"
          (or (uiop:getenv "DARTER_YOUTUBE_STRESS_URL")
              "https://www.youtube.com/watch?v=aqz-KE-bpKQ")))
        (until-js "!window.darterPreviousDocument && location.hostname==='www.youtube.com' && !!document.querySelector('#movie_player') && document.querySelector('video')?.readyState>=2" 120)
        (snapshot "PLAYER READY")
        ;; Record full-page completion separately from playable media.
        (handler-case
            (progn (until-js "document.readyState==='complete'" 90)
                   (format t "~&[YOUTUBE STRESS DOCUMENT COMPLETE]~%"))
          (error (e)
            (snapshot "DOCUMENT TIMEOUT")
            (error "YouTube full load failed: ~a" e)))
        (js "document.querySelector('#movie_player').pauseVideo();true")
        (until-js "document.querySelector('video').paused")
        (click 400 260)
        (until-js "!document.querySelector('video').paused && document.querySelector('video').currentTime>0.5")
        (resize 640 480 1120 640)
        (js "window.darterVideoFrames=0;window.darterLastFrame=0;window.darterFrameObserver=(now,meta)=>{window.darterVideoFrames++;window.darterLastFrame=meta.mediaTime;document.querySelector('video').requestVideoFrameCallback(window.darterFrameObserver)};document.querySelector('video').requestVideoFrameCallback(window.darterFrameObserver);true")
        (loop for quality in '("medium" "large" "hd720" "hd1080")
              for height in '(360 480 720 1080)
              for target in '(0 60 120 180)
              do
          (js (format nil "(()=>{let p=document.querySelector('#movie_player');p.setPlaybackQualityRange(~s,~s);p.setPlaybackQuality(~s);return true})()" quality quality quality))
          (until-js (format nil "document.querySelector('video').videoHeight===~d" height) 90)
          (js (format nil "document.querySelector('#movie_player').seekTo(~d,true);true" target))
          (until-js (format nil "(()=>{let v=document.querySelector('video');return v.readyState>=3&&!v.paused&&v.currentTime>~d+1&&window.darterLastFrame>~d})()" target target) 90)
          (js "window.stressLastTime=document.querySelector('video').currentTime;window.stressLastFrames=window.darterVideoFrames;window.stressStart={callbacks:window.darterVideoFrames,time:document.querySelector('video').currentTime,wall:performance.now(),total:document.querySelector('video').getVideoPlaybackQuality().totalVideoFrames,dropped:document.querySelector('video').getVideoPlaybackQuality().droppedVideoFrames};true")
          (snapshot (format nil "BEGIN ~dp" height))
          (dotimes (sample 6)
            (sleep 10)
            (snapshot (format nil "~dp SAMPLE ~d" height (1+ sample)))
            (until-js "(()=>{let v=document.querySelector('video');return !v.error&&!v.paused&&v.currentTime>stressLastTime+2&&window.darterVideoFrames>stressLastFrames+5})()" 20)
            (js "window.stressLastTime=document.querySelector('video').currentTime;window.stressLastFrames=window.darterVideoFrames;true")
            ;; Repeated edge drags while the native engine decodes and plays.
            (when (= sample 2)
              (resize 1120 640 800 560)
              (resize 800 560 1120 640)))
          (js "JSON.stringify({mediaSeconds:document.querySelector('video').currentTime-stressStart.time,wallSeconds:(performance.now()-stressStart.wall)/1000,presentedCallbacks:window.darterVideoFrames-stressStart.callbacks})")
          (until-js "document.querySelector('video').currentTime>stressStart.time+30" 30)
          (nyxt-app-shot (format nil "youtube-stress-~dp" height))
          (format t "~&[YOUTUBE STRESS ~dp ADVANCING FRAMES AND RESIZE PASS]~%" height))
        ;; Native pointer toggles pause/play; seek to the far end of the film.
        (click 400 260)
        (until-js "document.querySelector('video').paused")
        (click 400 260)
        (until-js "!document.querySelector('video').paused")
        (js "document.querySelector('#movie_player').seekTo(document.querySelector('video').duration-20,true);true")
        (until-js "document.querySelector('video').ended" 90)
        (snapshot "LONG VIDEO EOS")
        (format t "~&[YOUTUBE STRESS QUALIFICATION PASS]~%"))
      (ignore-errors (snapshot "FINAL DIAGNOSTICS")))))
