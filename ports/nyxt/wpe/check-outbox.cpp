#include "nyxt-outbox.hpp"
#include <cassert>
#include <cstdio>
using namespace NyxtWire;
int main(){
    Outbox q;char frame[64];memset(frame,3,sizeof frame);
    assert(q.push({1100,1,0,4,4,64},frame,1));
    std::vector<char> wire;
    auto stalled=[&](char* p,size_t n)->long{
        if(wire.size()>=7){errno=EAGAIN;return -1;}
        n=std::min(n,size_t(7));wire.insert(wire.end(),p,p+n);return n;};
    assert(q.pump(2,stalled));assert(wire.size()==7);
    // Replacing a view never splices into a partially transmitted packet.
    for(unsigned i=0;i<1000;++i){frame[0]=i%100;assert(q.push({1100,1,0,4,4,64},frame,3+i));}
    assert(q.coalesced==999 && q.pendingFrames()==1);
    assert(q.push({1000,0,42,0,0,2},"ok",1004));
    auto drain=[&](char* p,size_t n)->long{n=std::min(n,size_t(5));wire.insert(wire.end(),p,p+n);return n;};
    for(int i=0;i<100&&!q.empty();++i)assert(q.pump(2000,drain));
    assert(q.empty());size_t at=0;unsigned ops[]={1100,1000,1100};
    for(auto op:ops){Header h;memcpy(&h,wire.data()+at,sizeof h);assert(h.op==op);
        if(at==0)assert(wire[at+sizeof h]==3);
        if(op==1000)assert(h.seq==42);
        at+=sizeof h+h.n;}
    assert(at==wire.size() && wire[wire.size()-64]==99);
    assert(!q.controlBytes && !q.frameBytes);
    for(unsigned i=0;i<100;++i)assert(q.push({1100,i,0,4,4,64},frame,3000));
    assert(q.pendingFrames()==64 && q.evicted==36);
    q.discardFrames(99);assert(q.pendingFrames()==63);
    Outbox controls;
    for(unsigned i=0;i<256;++i)assert(controls.push({1000,0,i,0,0,0},nullptr,1));
    assert(!controls.push({1000,0,999,0,0,0},nullptr,2));
    assert(!controls.pump(10000001,drain));
    // No busy retry inside one pump when the receiver is blocked.
    Outbox blocked;assert(blocked.push({1000,0,1,0,0,0},nullptr,1));
    int calls=0;assert(blocked.pump(2,[&](char*,size_t)->long{++calls;errno=EAGAIN;return -1;}));
    assert(calls==1);
    Outbox large;std::vector<char> pixels(Outbox::packetLimit);
    for(unsigned i=0;i<10;++i){
        assert(large.push({1100,i,0,2048,2048,static_cast<uint32_t>(pixels.size())},pixels.data(),1));
        assert(large.frameBytes<=Outbox::frameLimit);
    }
    assert(large.evicted>0);
    assert(large.push({1000,0,1,0,0,static_cast<uint32_t>(pixels.size())},pixels.data(),1));
    assert(!large.push({1000,0,2,0,0,0},nullptr,1));
    puts("[NYXT OUTBOX FRAMING BOUNDS PASS]");
}
