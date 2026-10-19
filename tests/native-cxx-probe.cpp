#include "native-cxx-probe.hpp"
#include <algorithm>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>
#include <new>
#include <stdexcept>
#include <string>
#include <sstream>
#include <fstream>
#include <filesystem>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <random>
#include <locale.h>
#include <wchar.h>
#include <cerrno>
#include <thread>
#include <vector>
#include <cxxabi.h>
#include <pthread.h>

int initialization_order;
std::atomic<int> unwound{0}, static_constructions{0}, tls_destroyed{0};
static const char *artifact;
static void append(char c) {
    FILE *f = fopen(artifact, "a");
    if (!f || fwrite(&c, 1, 1, f) != 1 || fclose(f)) _Exit(99);
}
__attribute__((constructor(101))) static void first() { initialization_order = 1; }
struct Global {
    int value;
    Global() : value(initialization_order) {}
    ~Global() { if (artifact) append('G'); }
} global;
__attribute__((destructor(201))) static void finished() { if (artifact) append('Z'); }
struct Local {
    int value = 17;
    bool main = false;
    ~Local() { ++tls_destroyed; if (main) append('T'); }
};
thread_local Local local;
thread_local int initialized = 29;
struct alignas(256) Aligned { long value = 91; };
static int attempts, new_handler_calls;
static int retry() {
    static int value = [] { if (++attempts == 1) throw 19; return 67; }();
    return value;
}
static int finalized;
static void increment(void *) { ++finalized; }
static pthread_key_t key;
static int key_passes;
static void key_dtor(void *) { if (++key_passes < 3) pthread_setspecific(key, &key); }
static void report(const char *name) { printf("[CXX %s PASS]\n", name); }

static void filesystem_probe() {
    namespace fs=std::filesystem;
    fs::path root=std::string(artifact)+".fs";
    fs::path outside=std::string(artifact)+".outside";
    assert(fs::create_directories(root/"a"/"b"));
    assert(fs::create_directories(outside));
    { std::ofstream f(root/"a"/"b"/"source");f<<"native filesystem";assert(f.good()); }
    { std::ofstream f(outside/"keep");f<<"keep";assert(f.good()); }
    assert(fs::file_size(root/"a"/"b"/"source")==17);
    assert(pathconf(root.c_str(),_PC_PATH_MAX)==4096);
    errno=0;assert(pathconf((root/"absent").c_str(),_PC_PATH_MAX)==-1 && errno==ENOENT);
    errno=0;assert(pathconf(root.c_str(),-1)==-1 && errno==EINVAL);
    char cwd[4096];assert(getcwd(cwd,sizeof cwd));
    assert(fs::current_path()==fs::path(cwd));
    unsigned seen=0;
    for(const auto &entry:fs::directory_iterator(root/"a"/"b")) {
        assert(entry.is_regular_file() && entry.file_size()==17);++seen;
    }
    assert(seen==1);
    fs::copy(root/"a",root/"copy",fs::copy_options::recursive);
    assert(fs::file_size(root/"copy"/"b"/"source")==17);
    fs::rename(root/"copy"/"b"/"source",root/"copy"/"b"/"renamed");
    fs::permissions(root/"copy"/"b"/"renamed",fs::perms::owner_read);
    assert((fs::status(root/"copy"/"b"/"renamed").permissions()&fs::perms::all)==fs::perms::owner_read);
    char before[4096],after[4096];assert(getcwd(before,sizeof before));
    int directory=open((root/"a"/"b").c_str(),O_RDONLY|O_DIRECTORY);
    assert(directory>=0);
    int fd=openat(directory,"relative",O_CREAT|O_EXCL|O_RDWR|O_CLOEXEC,0600);
    assert(fd>=0 && fcntl(fd,F_GETFD)==FD_CLOEXEC && write(fd,"fd",2)==2);
    assert(fchmodat(directory,"relative",0400,0)==0);
    struct stat st{};assert(fstat(fd,&st)==0 && (st.st_mode&0777)==0400);
    errno=0;assert(fchmodat(directory,"relative",0600,0x8000)==-1 && errno==EINVAL);
    assert(fchmodat(-1,(root/"a"/"b"/"relative").c_str(),0600,0)==0);
    errno=0;assert(openat(directory,"",O_RDONLY)==-1 && errno==ENOENT);
    errno=0;assert(unlinkat(directory,"relative",AT_REMOVEDIR)==-1 && errno==ENOTDIR);
    assert(unlinkat(directory,"relative",0)==0);
    assert(lseek(fd,0,SEEK_SET)==0);char bytes[2];assert(read(fd,bytes,2)==2 && bytes[0]=='f');
    close(fd);close(directory);
    assert(getcwd(after,sizeof after) && !strcmp(before,after));
    fs::create_directory_symlink(outside,root/"escape");
    fs::create_directory_symlink(root,root/"cycle");
    assert(fs::is_symlink(fs::symlink_status(root/"escape")));
    errno=0;assert(open((root/"escape").c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW)==-1 && errno==ELOOP);
    errno=0;assert(open((root/"escape").c_str(),O_CREAT|O_EXCL|O_RDWR,0600)==-1 && errno==EEXIST);
    std::error_code ec;
    assert(fs::remove_all(root,ec)==9 && !ec);
    assert(!fs::exists(root) && fs::file_size(outside/"keep")==4);
    assert(fs::remove_all(outside,ec)==2 && !ec);
    assert(fs::remove_all(root,ec)==0 && !ec);
    report("FILESYSTEM");
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "terminate")) {
        std::set_terminate([] { _Exit(77); });
        throw std::runtime_error("uncaught");
    }
    assert(argc == 2);
    artifact = argv[1];
    FILE *f = fopen(artifact, "w"); assert(f); fclose(f);
    assert(global.value == 12 && initialization_order == 12);
    report("CONSTRUCTORS");
    std::ostringstream formatted;
    formatted << 42 << ' ' << 1.5;
    assert(formatted.str() == "42 1.5");
    std::istringstream input("37 2.5");
    int integer = 0; double fraction = 0;
    input >> integer >> fraction;
    assert(integer == 37 && fraction == 2.5 && !input.fail());
    assert(std::to_wstring(123) == L"123");
    assert(std::wstring(L"darterfly").substr(2, 4) == L"rter");
    assert(newlocale(LC_ALL_MASK, "C", nullptr));
    assert(!newlocale(LC_ALL_MASK, "not-a-locale", nullptr) && errno == ENOENT);
    mbstate_t state{}; wchar_t wc = 0;
    assert(mbrtowc(&wc, "A", 1, &state) == 1 && wc == L'A');
    assert(mbrtowc(&wc, "\x80", 1, &state) == size_t(-1) && errno == EILSEQ);
    int major = 0, minor = 0, consumed = 0;
    assert(sscanf("19.1tail", "%d.%d%n", &major, &minor, &consumed) == 2);
    assert(major == 19 && minor == 1 && consumed == 4);
    std::random_device random;
    (void)random();
    {
        std::string path = std::string(artifact) + ".stream";
        { std::ofstream file(path); file << "darterfly " << 19; assert(file.good()); }
        std::ifstream file(path);
        std::string word; int version = 0;
        file >> word >> version;
        assert(word == "darterfly" && version == 19 && !file.fail());
    }
    report("STREAMS-LOCALE");
    filesystem_probe();
    std::vector<int> numbers{9, 3, 7, 1};
    numbers.reserve(128); std::sort(numbers.begin(), numbers.end());
    std::string text(100, 'x'); text.replace(3, 3, "abc");
    auto shared = std::make_shared<std::string>(text);
    auto copy = shared;
    assert(numbers[0] == 1 && numbers[3] == 9 && copy->substr(3, 3) == "abc");
    auto aligned = new Aligned;
    assert((reinterpret_cast<unsigned long>(aligned) & 255) == 0 && aligned->value == 91);
    delete aligned;
    std::unique_ptr<int[]> array(new int[64]{}); assert(array[63] == 0);
    auto quotient = std::div(-17, 5);
    auto wide = std::ldiv(-10000000017L, 5L);
    auto widest = std::lldiv(-10000000017LL, 5LL);
    assert(quotient.quot == -3 && quotient.rem == -2);
    assert(wide.quot == -2000000003L && wide.rem == -2);
    assert(widest.quot == wide.quot && widest.rem == wide.rem);
    report("STL-ALLOCATION");
    std::set_new_handler([] { ++new_handler_calls; std::set_new_handler(nullptr); });
    try { (void)::operator new(static_cast<std::size_t>(-1)); assert(false); }
    catch (const std::bad_alloc &) { assert(new_handler_calls == 1); }
    assert(::operator new(static_cast<std::size_t>(-1), std::nothrow) == nullptr);
    report("ALLOCATION-FAILURE");
    auto base = std::unique_ptr<Base>(make_derived());
    Base *raw_base = base.get();
    assert(dynamic_cast<Derived *>(raw_base) && typeid(*raw_base) == typeid(Derived));
    assert(base->value() == 83);
    int demangle_status;
    char *name = abi::__cxa_demangle(typeid(Derived).name(), nullptr, nullptr, &demangle_status);
    assert(demangle_status == 0 && !strcmp(name, "Derived")); free(name);
    report("RTTI");
    std::exception_ptr saved;
    try { throw_across_units(); assert(false); }
    catch (const std::runtime_error &e) {
        assert(!strcmp(e.what(), "across translation units"));
        saved = std::current_exception();
    }
    try { std::rethrow_exception(saved); assert(false); }
    catch (const std::runtime_error &) { assert(unwound == 1); }
    try { numbers.at(999); assert(false); }
    catch (const std::out_of_range &) {}
    report("EXCEPTIONS");
    try { retry(); assert(false); } catch (int n) { assert(n == 19); }
    assert(retry() == 67 && attempts == 2);
    report("GUARD-RETRY");
    std::mutex mutex;
    std::condition_variable cv;
    int ready = 0;
    bool go = false;
    std::thread threads[4];
    for (auto &thread : threads) thread = std::thread([&] {
        assert(local.value == 17 && initialized == 29);
        local.value = 81; initialized = 3;
        { std::unique_lock<std::mutex> lock(mutex); ++ready; cv.notify_all();
          cv.wait(lock, [&] { return go; }); }
        assert(shared_static().value == 73 && other_static() == 73);
        try { throw_across_units(); } catch (const std::runtime_error &) {}
    });
    { std::unique_lock<std::mutex> lock(mutex);
      cv.wait(lock, [&] { return ready == 4; }); go = true; cv.notify_all(); }
    for (auto &thread : threads) thread.join();
    assert(tls_destroyed == 4 && local.value == 17 && initialized == 29);
    assert(static_constructions == 1 && unwound == 5);
    local.main = true;
    report("THREADS-TLS-GUARDS");
    assert(pthread_key_create(&key, key_dtor) == 0);
    std::thread key_thread([] { assert(pthread_setspecific(key, &key) == 0); });
    key_thread.join(); assert(key_passes == 3); pthread_key_delete(key);
    report("KEY-DESTRUCTORS");
    int dso;
    for (int i = 0; i != 80; ++i) assert(__cxa_atexit(increment, nullptr, &dso) == 0);
    __cxa_finalize(&dso); __cxa_finalize(&dso);
    assert(finalized == 80);
    assert(std::atexit([] { append('A'); }) == 0);
    report("FINALIZE");
    auto before = std::chrono::steady_clock::now();
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
    assert(std::chrono::steady_clock::now() >= before);
    report("CLOCK");
    return 42;
}
