#pragma once
#include <atomic>
struct Base { virtual ~Base(); virtual int value() const = 0; };
struct Derived : Base { int value() const override; };
extern std::atomic<int> unwound;
void throw_across_units();
Base *make_derived();
int other_static();
extern int initialization_order;
extern std::atomic<int> static_constructions;
struct Once {
    int value;
    Once() : value(73) { ++static_constructions; }
};
inline Once &shared_static() { static Once value; return value; }
