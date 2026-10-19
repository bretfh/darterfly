(list (channel
       (name 'nonguix)
       (url "https://gitlab.com/nonguix/nonguix")
       (branch "master")
       (commit "d35a2f8f22023426ccf3598fa7079b09bb821e3e")
       (introduction
        (make-channel-introduction
         "897c1a470da759236cc11798f4e0a5f7d4d59fbc"
         (openpgp-fingerprint
          "2A39 3FFF 68F4 EF7A 3D29  12AF 6F51 20A0 22FB B2D5"))))
      (channel
       (name 'bfh-dots)
       (url "file:///home/bfh/dots")
       (branch "main")
       (commit "1e3ba5d3a903fb54a996c3aeab9fcd692eb484f5"))
      (channel
       (name 'guile-webui)
       (url "file:///home/bfh/git/guile/guile-webui")
       (branch "master")
       (commit "b8875549e731fc072f746f6fd03b0bbfa8130f08"))
      (channel
       (name 'guile-canary)
       (url "file:///home/bfh/git/guile/guile-canary")
       (branch "main")
       (commit "eef3d746bf76ad4540d0cbd0d53989427a017ff9"))
      (channel
       (name 'delve)
       (url "file:///home/bfh/git/guile/delve")
       (branch "main")
       (commit "dd71a66b9840f2b6b61b31d83612762a6727f599"))
      (channel
       (name 'guix)
       (url "https://git.savannah.gnu.org/git/guix.git")
       (branch "master")
       (commit "fc665909ddc733882c7a1bf1cd3db2273bcaf739")
       (introduction
        (make-channel-introduction
         "9edb3f66fd807b096b48283debdcddccfea34bad"
         (openpgp-fingerprint
          "BBB0 2DDF 2CEA F6A8 0D1D  E643 A2A0 6DF2 A33A 54FA")))))
