#include "native-cxx-probe.hpp"
#include <stdexcept>
Base::~Base() = default;
int Derived::value() const { return 83; }
Base *make_derived() { return new Derived; }
int other_static() { return shared_static().value; }
struct Cleanup { ~Cleanup() { ++unwound; } };
void throw_across_units() {
    Cleanup cleanup;
    throw std::runtime_error("across translation units");
}
__attribute__((constructor(201))) static void second() {
    initialization_order = initialization_order * 10 + 2;
}
