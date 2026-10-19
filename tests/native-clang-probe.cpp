#include <algorithm>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#include <sstream>
#include <thread>
#include <atomic>
#ifndef ANSWER
#define ANSWER 42
#endif
static int initialized;
struct Global { Global() { initialized = 7; } } global;
thread_local int local = 11;
static std::atomic<int> destroyed{0};
struct Guard { ~Guard() { ++destroyed; } };
int main() {
    std::vector<int> data{9, 2, 5};
    std::sort(data.begin(), data.end());
    auto text = std::make_unique<std::string>("compiled inside darterfly");
    try { Guard guard; throw std::runtime_error(*text); }
    catch (const std::exception &e) {
        if (std::string(e.what()) != *text || destroyed != 1) return 91;
    }
    int child = 0;
    std::thread worker([&] { local = 23; child = local; });
    worker.join();
    std::ostringstream output;
    output << data.front() << ':' << child;
    if (initialized != 7 || local != 11 || output.str() != "2:23") return 92;
    std::puts("[CLANG CXX-PROGRAM PASS]");
    return ANSWER;
}
