// Single-owner transport queue: only the GLib thread calls these methods.
// Partial packets are indivisible. Unsent frames may be replaced; replies may not.
#pragma once
#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstring>
#include <deque>
#include <memory>
#include <vector>
namespace NyxtWire {
struct Header { uint32_t op,id,seq,a,b,n; };
static_assert(sizeof(Header)==24);
class Outbox {
    struct Packet {
        unsigned id; bool frame; int64_t born; size_t at=0;
        std::vector<char> bytes;
        Packet(Header h,const void* data,int64_t now):id(h.id),frame(h.op==1100),born(now),bytes(sizeof h+h.n) {
            memcpy(bytes.data(),&h,sizeof h);
            if(h.n)memcpy(bytes.data()+sizeof h,data,h.n);
        }
    };
    std::deque<Packet> controls,frames;
    std::unique_ptr<Packet> active;
    unsigned controlBurst=0;
public:
    static constexpr size_t packetLimit=16*1024*1024;
    static constexpr size_t controlLimit=packetLimit+sizeof(Header),frameLimit=64*1024*1024;
    static constexpr unsigned controlSlots=256,frameSlots=64;
    size_t controlBytes=0,frameBytes=0,peakFrameBytes=0;
    unsigned controlCount=0,peakFrames=0;
    uint64_t coalesced=0,evicted=0,sentFrames=0,blocked=0,writeCalls=0;
    size_t pendingFrames() const { return frames.size(); }
    bool empty() const { return !active && controls.empty() && frames.empty(); }
    void discardFrames(unsigned id) {
        for(auto it=frames.begin();it!=frames.end();)
            if(it->id==id){frameBytes-=it->bytes.size();it=frames.erase(it);}else ++it;
        // A packet already on the wire must finish, even if its view died.
    }
    bool push(Header h,const void* data,int64_t now) {
        if(h.n>packetLimit)return false;
        const size_t n=sizeof h+h.n;
        if(h.op!=1100){
            if(controlCount>=controlSlots || controlBytes+n>controlLimit)return false;
            controls.emplace_back(h,data,now);controlBytes+=n;++controlCount;return true;
        }
        for(auto& p:frames)if(p.id==h.id){
            frameBytes-=p.bytes.size();p=Packet(h,data,now);frameBytes+=n;++coalesced;
            // Growing a view can exceed the byte cap; evict oldest other views.
            while(frameBytes>frameLimit){frameBytes-=frames.front().bytes.size();frames.pop_front();++evicted;}
            peakFrameBytes=std::max(peakFrameBytes,frameBytes);return true;
        }
        while(frames.size()>=frameSlots || frameBytes+n>frameLimit){
            frameBytes-=frames.front().bytes.size();frames.pop_front();++evicted;
        }
        frames.emplace_back(h,data,now);frameBytes+=n;
        peakFrameBytes=std::max(peakFrameBytes,frameBytes);
        peakFrames=std::max(peakFrames,static_cast<unsigned>(frames.size()));return true;
    }
    template<class Writer> bool pump(int64_t now,Writer write) {
        // Give GLib and input a turn even while the socket is writable.
        size_t budget=128*1024;
        for(unsigned calls=0;calls<16 && budget;++calls){
            if(!active){
                bool control=!controls.empty() && (frames.empty() || controlBurst<8);
                if(control){active=std::make_unique<Packet>(std::move(controls.front()));controls.pop_front();++controlBurst;}
                else if(!frames.empty()){
                    active=std::make_unique<Packet>(std::move(frames.front()));frames.pop_front();
                    frameBytes-=active->bytes.size();active->born=now;controlBurst=0;
                } else return true;
            }
            if(now-active->born>=10000000)return false;
            size_t size=std::min({size_t(32768),budget,active->bytes.size()-active->at});
            ++writeCalls;auto n=write(active->bytes.data()+active->at,size);
            if(n<0 && (errno==EAGAIN || errno==EINTR)){++blocked;return true;}
            if(n<=0)return false;
            active->at+=n;budget-=n;
            if(active->at==active->bytes.size()){
                if(active->frame)++sentFrames;
                else{controlBytes-=active->bytes.size();--controlCount;}
                active.reset();
            }
        }
        return true;
    }
};
}
