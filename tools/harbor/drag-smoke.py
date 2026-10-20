#!/usr/bin/env python3
"""Exercise live Welcome movement, resize, zoom and actions without installing.
Run on a fresh live welcome with no other document window covering the desktop.
"""
import time
from smoke import move,button,click,key,wait_pixel,shot,frame,pixel,PAPER
from vm import qmp


def drag(x,y,to_x,to_y):
    move(x,y)
    button(True)
    for i in range(1,13):
        nx=x+(to_x-x)*i/12
        ny=y+(to_y-y)*i/12
        qmp('input-send-event',{'events':[
            {'type':'abs','data':{'axis':'x','value':int(nx*32768/1280)}},
            {'type':'abs','data':{'axis':'y','value':int(ny*32768/800)}}]})
        time.sleep(.012)
    button(False)


def run():
    wait_pixel(900,450,PAPER,'fresh welcome')
    x,y=335,245
    for i,(nx,ny) in enumerate([(70,60),(500,400),(650,50),(0,480),(335,245)]*4):
        drag(x+200,y+13,nx+200,ny+13)
        x,y=nx,ny
        wait_pixel(x+300,y+170,PAPER,f'installer survives drag {i+1}',timeout=3)
    shot('qa-installer-dragged')
    drag(943,553,1063,623)
    wait_pixel(1045,445,PAPER,'installer expands beyond its original frame',timeout=3)
    shot('qa-installer-expanded')
    drag(1063,623,943,553)
    wait_pixel(900,450,PAPER,'installer returns to its original size',timeout=3)
    click(395,258)
    wait_pixel(1100,600,PAPER,'installer zooms',timeout=3)
    # Navigation while zoomed exercises reconstructed footer anchoring.
    click(1080,661)
    time.sleep(.3)
    r,g,b=pixel(frame(),1176,654)
    assert r>g+35 and g>b,'Zoomed review must have a destructive action at the right edge'
    shot('qa-installer-zoomed-review')
    key('esc')
    click(100,57)
    wait_pixel(900,450,PAPER,'installer restores after zoomed navigation',timeout=3)
    click(788,532)
    time.sleep(.3)
    r,g,b=pixel(frame(),866,524)
    assert r>g+35 and g>b,'Install still opens disk review after dragging and resizing'
    print('PASS: installer actions remain responsive after movement and resize',flush=True)
    key('esc')
    move(1030,650)
    shot('qa-installer-drag-fixed')
    print('PASS: installer drag/resize checks complete; no disk was erased',flush=True)


if __name__=='__main__':
    run()
