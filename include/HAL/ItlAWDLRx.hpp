#ifndef ItlAWDLRx_hpp
#define ItlAWDLRx_hpp

#include <net80211/ieee80211_var.h>
#include <net80211/ieee80211_proto.h>

enum class ItlAWDLGroupRx { None, Data, Sync };

inline const uint8_t *
itlAWDLBssid(const struct ieee80211com *ic)
{
    static const uint8_t bssid[] = { 0x00, 0x25, 0x00, 0xff, 0x94, 0x73 };
    return ic->ic_awdl_bssid_valid ? ic->ic_awdl_bssid : bssid;
}

inline ItlAWDLGroupRx
itlAWDLClassifyGroupRx(const struct ieee80211com *ic, const void *frame,
    size_t len, unsigned padding, bool reversedBssid = false)
{
    if (!ic->ic_awdl_addr_gen || len < sizeof(struct ieee80211_frame))
        return ItlAWDLGroupRx::None;
    const auto *wh = static_cast<const struct ieee80211_frame *>(frame);
    if (!IEEE80211_IS_MULTICAST(wh->i_addr1))
        return ItlAWDLGroupRx::None;
    const uint8_t type = wh->i_fc[0] & IEEE80211_FC0_TYPE_MASK;
    const uint8_t subtype = wh->i_fc[0] & IEEE80211_FC0_SUBTYPE_MASK;
    if (type == IEEE80211_FC0_TYPE_DATA) {
        const uint8_t *bssid = itlAWDLBssid(ic);
        uint8_t normalized[IEEE80211_ADDR_LEN];
        const uint8_t *rxBssid = wh->i_addr3;
        if (reversedBssid && ieee80211_has_qos(wh)) {
            for (unsigned i = 0; i < sizeof(normalized); ++i)
                normalized[i] = rxBssid[sizeof(normalized) - 1 - i];
            rxBssid = normalized;
        }
        return IEEE80211_ADDR_EQ(rxBssid, bssid) ? ItlAWDLGroupRx::Data : ItlAWDLGroupRx::None;
    }
    if (type != IEEE80211_FC0_TYPE_MGT ||
        (subtype != IEEE80211_FC0_SUBTYPE_ACTION && subtype != IEEE80211_FC0_SUBTYPE_ACTION_NOACK))
        return ItlAWDLGroupRx::None;
    const size_t body = ieee80211_get_hdrlen(wh) + padding;
    static const uint8_t action[] = { IEEE80211_CATEG_VENDOR, 0x00, 0x17, 0xf2, 0x08 };
    const auto *bytes = static_cast<const uint8_t *>(frame);
    if (len < body + 16 || memcmp(bytes + body, action, sizeof(action)))
        return ItlAWDLGroupRx::None;
    return bytes[body + 6] == 0 || bytes[body + 6] == 3 ? ItlAWDLGroupRx::Sync : ItlAWDLGroupRx::None;
}

inline void
itlAWDLCountGroupRx(struct ieee80211com *ic, ItlAWDLGroupRx group, bool onRoc)
{
    if (group == ItlAWDLGroupRx::Sync)
        ic->ic_awdl_fw_group_sync[onRoc]++;
    else if (group == ItlAWDLGroupRx::Data)
        ic->ic_awdl_fw_group_data[onRoc]++;
}

#endif
