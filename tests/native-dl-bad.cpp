extern "C" int missing_engine_service();
extern "C" int bad_call() { return missing_engine_service(); }
