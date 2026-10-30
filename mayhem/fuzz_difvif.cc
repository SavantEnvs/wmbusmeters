// libFuzzer form of upstream's src/fuzz.cc: feed raw DIF/VIF record bytes to parseDV().
#include "dvparser.h"
#include "wmbus.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

using namespace std;

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    vector<uchar> databytes(data, data + size);
    unordered_map<string, pair<int, DVEntry>> dv_entries;

    Telegram t;
    vector<uchar>::iterator i = databytes.begin();

    parseDV(&t, databytes, i, databytes.size(), &dv_entries);
    return 0;
}
