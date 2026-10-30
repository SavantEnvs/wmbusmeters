// Feed a whole wmbus telegram (DLL crcs already removed, as in the simulation files) through the
// same path as `wmbusmeters --listento=any stdin <name> auto <id> <key>`: header parse, driver
// auto-detection, decryption, DV parse and field extraction.
#include "log.h"
#include "meters.h"
#include "wmbus.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

using namespace std;

extern "C" int LLVMFuzzerInitialize(int *, char ***)
{
    silentLogging(true);
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size == 0) return -1;

    vector<uchar> frame(data, data + size);

    shared_ptr<MeterManager> manager = createMeterManager(false);
    MeterInfo mi;
    mi.parse("fuzz", "auto", "*", "00000000000000000000000000000000");
    manager->addMeterTemplate(mi);

    AboutTelegram about("fuzz", 0, LinkMode::Any, FrameType::WMBUS);
    manager->handleTelegram(about, frame, true);
    return 0;
}
