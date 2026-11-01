// The relay inside the game: the same job, files and packets as net/pbzcoop_net.py (read its header first), so a
// C++ relay and a Python one can be partners and the same tests cover both. UE4SS Lua can't open sockets, so this
// runs on its own thread in main.dll (main_dll.cpp); relay_cli.cpp wraps it as a console tool for the tests.
#pragma once
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bcrypt.h>
#include <timeapi.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "crypto.hpp"
#include "json.hpp"

namespace relay {

constexpr double TICK = 0.05;          // 20 sends per second
constexpr double WATCH = 0.005;        // how often the mod's files are checked for something new to send at once
constexpr double PING_EVERY = 1.0;
constexpr double PEER_TIMEOUT = 3.0;
constexpr double PRUNE_AFTER = 12.0;   // s: a peer silent this long loses its slot (and its snapshot file)
constexpr double HELLO_EVERY = 2.0;
constexpr double ALIVE_TIMEOUT = 180.0; // s without a heartbeat from the mod before the relay gives up (it's sent from
                                        // the game thread, which stands still through a long load)
constexpr int PROTOCOL = 3;
constexpr size_t MAX_EVENTS_PER_PACKET = 40;
constexpr size_t MAX_EVENT_BYTES = 1000;  // and this much text, so a packet stays under a VPN's 1280-byte limit
constexpr size_t MAX_SNAPSHOT_BYTES = 48000;
constexpr double ENEMY_EVERY = 0.1;       // enemies go in their own, larger packet: losing one can't cost the position
constexpr double SESSION_EVERY = 1.0;     // the event session is repeated this often when no events are pending
constexpr int MAX_PACKETS_PER_RECEIVE = 256;
constexpr size_t MAX_ACKED_SESSIONS = 16;   // ack session ids come from the network: don't keep them forever

inline std::wstring widen(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring w(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
    return w;
}

inline std::string narrow(const std::wstring& w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
    std::string s(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), s.data(), n, nullptr, nullptr);
    return s;
}

inline double monotonic() {
    static const double freq = [] {
        LARGE_INTEGER f;
        QueryPerformanceFrequency(&f);
        return static_cast<double>(f.QuadPart);
    }();
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    return c.QuadPart / freq;
}

inline double wall_seconds() {
    FILETIME ft;
    GetSystemTimePreciseAsFileTime(&ft);
    ULARGE_INTEGER u;
    u.LowPart = ft.dwLowDateTime;
    u.HighPart = ft.dwHighDateTime;
    return (u.QuadPart - 116444736000000000ULL) / 1e7;
}

// Lua's text mode writes CRLF: lines are normalized here, as Python's text mode does.
inline std::string read_text(const std::wstring& path) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return {};
    std::string out;
    char buf[16384];
    DWORD got = 0;
    while (ReadFile(h, buf, sizeof buf, &got, nullptr) && got > 0) out.append(buf, got);
    CloseHandle(h);
    if (out.find('\r') != std::string::npos) {
        std::string clean;
        clean.reserve(out.size());
        for (size_t i = 0; i < out.size(); i++) {
            if (out[i] == '\r') {
                if (i + 1 < out.size() && out[i + 1] == '\n') continue;
                clean.push_back('\n');
            } else {
                clean.push_back(out[i]);
            }
        }
        out.swap(clean);
    }
    return out;
}

// Delete a file, ignoring "it isn't there": a peer's snapshot that is already gone is not a problem.
inline void remove_quietly(const std::wstring& path) {
    DeleteFileW(path.c_str());
}

// read_text, minus a last line the mod is still writing (no newline yet): it is sent once it's complete.
inline std::string read_complete_lines(const std::wstring& path) {
    std::string text = read_text(path);
    size_t last = text.rfind('\n');
    text.resize(last == std::string::npos ? 0 : last + 1);
    return text;
}

// False if the file couldn't be written this time; the next tick writes fresh data anyway. The mod may have the
// file open for a moment, and Windows can briefly refuse a rename for other reasons: retry, then skip.
inline bool write_atomic(const std::wstring& path, const std::string& text) {
    const std::wstring tmp = path + L".tmp";
    for (int attempt = 0; attempt < 5; attempt++) {
        HANDLE h = CreateFileW(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h != INVALID_HANDLE_VALUE) {
            DWORD wrote = 0;
            bool ok = text.empty() ||
                      (WriteFile(h, text.data(), static_cast<DWORD>(text.size()), &wrote, nullptr) &&
                       wrote == text.size());
            CloseHandle(h);
            if (ok && MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING)) return true;
        }
        Sleep(2 * (attempt + 1));
    }
    return false;
}

// False if the lines couldn't be appended (the caller keeps them and retries next time).
inline bool append_lines(const std::wstring& path, const std::vector<std::string>& lines) {
    std::string text;
    for (const auto& line : lines) {
        text += line;
        text.push_back('\n');
    }
    for (int attempt = 0; attempt < 5; attempt++) {
        HANDLE h = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr,
                               OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h != INVALID_HANDLE_VALUE) {
            DWORD wrote = 0;
            bool ok = WriteFile(h, text.data(), static_cast<DWORD>(text.size()), &wrote, nullptr) &&
                      wrote == text.size();
            CloseHandle(h);
            if (ok) return true;
        }
        Sleep(2 * (attempt + 1));
    }
    return false;
}

using Event = std::pair<long long, std::string>;   // id, whole line

struct ParsedEvents {
    std::optional<std::string> session;
    std::vector<Event> events;
};

inline std::string strip(const std::string& s) {
    size_t a = 0, b = s.size();
    while (a < b && std::isspace(static_cast<unsigned char>(s[a]))) a++;
    while (b > a && std::isspace(static_cast<unsigned char>(s[b - 1]))) b--;
    return s.substr(a, b - a);
}

inline ParsedEvents parse_events(const std::string& text) {
    ParsedEvents out;
    size_t pos = 0;
    while (pos < text.size()) {
        size_t end = text.find('\n', pos);
        if (end == std::string::npos) end = text.size();
        std::string line = text.substr(pos, end - pos);
        pos = end + 1;
        size_t space = line.find(' ');
        std::string head = line.substr(0, space);
        if (head.empty()) continue;
        if (head == "S" && space != std::string::npos) {
            out.session = strip(line.substr(space + 1));
        } else if (head.size() <= 12 && std::all_of(head.begin(), head.end(), [](char c) { return c >= '0' && c <= '9'; })) {
            out.events.emplace_back(std::strtoll(head.c_str(), nullptr, 10), line);
        }
    }
    return out;
}

// Writes the peer's events to net_events_in.txt exactly once each, in order.
class EventInbox {
public:
    explicit EventInbox(std::wstring path) : path_(std::move(path)) {}

    long long accept(const std::string& session, std::vector<Event> events) {
        if (!session_ || *session_ != session) {
            // The peer restarted its mod: start a fresh file so old events aren't replayed.
            if (!write_atomic(path_, "S " + session + "\n")) return 0;
            session_ = session;
            last_id = 0;
        }
        std::sort(events.begin(), events.end());
        std::vector<std::string> fresh;
        long long last = last_id;
        for (auto& [id, line] : events) {
            if (id == last + 1) {
                fresh.push_back(std::move(line));
                last = id;
            }
        }
        // Only acknowledged once written: if the write fails the peer keeps resending them.
        if (!fresh.empty() && append_lines(path_, fresh)) last_id = last;
        return last_id;
    }

    long long last_id = 0;

private:
    std::wstring path_;
    std::optional<std::string> session_;
};

// Where a partner can be: Tailscale (100.64.0.0/10), home networks, this PC, and the Hamachi (25/8) and Radmin
// (26/8) VPN ranges. The host takes packets only from these unless AllowAnyAddress is on.
inline bool address_allowed(uint32_t ip) {
    static const struct { uint32_t net, mask; } nets[] = {
        {0x64400000, 0xFFC00000}, {0x0A000000, 0xFF000000}, {0xAC100000, 0xFFF00000}, {0xC0A80000, 0xFFFF0000},
        {0xA9FE0000, 0xFFFF0000}, {0x7F000000, 0xFF000000}, {0x19000000, 0xFF000000}, {0x1A000000, 0xFF000000}};
    for (const auto& n : nets)
        if ((ip & n.mask) == n.net) return true;
    return false;
}

// Optional shared secret (Secret = ... in PhantomPact.ini): see Auth in pbzcoop_net.py for why each check exists.
// packet = MAGIC | role (1) | session (8) | counter (8) | time ms (8) | payload | HMAC-SHA256 (32)
class Auth {
public:
    static constexpr char MAGIC[] = "PPA1";
    static constexpr size_t HEADER = 4 + 1 + 8 + 8 + 8;
    static constexpr size_t TAG = 32;
    static constexpr double REPLAY_WINDOW_S = 120.0;
    static constexpr size_t SESSIONS_KEPT = 8;

    Auth(const std::string& secret, const std::string& role) {
        std::string master = crypto::scrypt(secret, "PhantomPact/relay/1", 1 << 14, 8, 32);
        key_ = crypto::hmac_sha256(master, "packet-mac");
        role_ = role == "host" ? 'H' : 'C';
        session_.resize(8);
        if (!BCRYPT_SUCCESS(BCryptGenRandom(nullptr, reinterpret_cast<PUCHAR>(session_.data()), 8,
                                            BCRYPT_USE_SYSTEM_PREFERRED_RNG)))
            throw std::runtime_error("no system random numbers for the Secret");
    }

    static void put_u64(std::string& out, uint64_t v) {
        for (int i = 7; i >= 0; i--) out.push_back(static_cast<char>(v >> (8 * i)));
    }
    static uint64_t get_u64(const char* p) {
        uint64_t v = 0;
        for (int i = 0; i < 8; i++) v = (v << 8) | static_cast<unsigned char>(p[i]);
        return v;
    }

    std::string seal(const std::string& payload) {
        std::string body(MAGIC, 4);
        body.push_back(role_);
        body += session_;
        put_u64(body, ++counter_);
        put_u64(body, static_cast<uint64_t>(wall_seconds() * 1000));
        body += payload;
        return body + crypto::hmac_sha256(key_, body);
    }

    // The payload of a valid packet from the other side, or nothing.
    std::optional<std::string> open(const std::string& data) {
        if (data.size() < HEADER + TAG || data.compare(0, 4, MAGIC, 4) != 0) return std::nullopt;
        std::string body = data.substr(0, data.size() - TAG);
        std::string expected = crypto::hmac_sha256(key_, body);
        unsigned char diff = 0;
        for (size_t i = 0; i < TAG; i++) diff |= static_cast<unsigned char>(expected[i] ^ data[body.size() + i]);
        if (diff) return std::nullopt;
        std::string session = body.substr(5, 8);
        uint64_t counter = get_u64(body.data() + 13);
        uint64_t sent_ms = get_u64(body.data() + 21);
        if (body[4] == role_ || session == session_) return std::nullopt;
        if (std::fabs(wall_seconds() * 1000 - static_cast<double>(sent_ms)) > REPLAY_WINDOW_S * 1000) return std::nullopt;
        auto it = std::find_if(seen_.begin(), seen_.end(), [&](const auto& s) { return s.first == session; });
        if (it != seen_.end()) {
            if (counter <= it->second) return std::nullopt;
            seen_.erase(it);
        }
        seen_.emplace_back(session, counter);
        while (seen_.size() > SESSIONS_KEPT) seen_.erase(seen_.begin());
        return body.substr(HEADER);
    }

private:
    std::string key_, session_;
    char role_ = 'C';
    uint64_t counter_ = 0;
    std::vector<std::pair<std::string, uint64_t>> seen_;   // oldest first: session, highest counter accepted
};

using Ini = std::map<std::string, std::string>;

inline std::string lower(std::string s) {
    for (auto& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

// Key (lowercase) -> value from PhantomPact.ini; ';' and '#' start comments. Empty if there's no file.
inline Ini read_ini(const std::wstring& path) {
    Ini out;
    std::string text = read_text(path);
    size_t pos = 0;
    while (pos < text.size()) {
        size_t end = text.find('\n', pos);
        if (end == std::string::npos) end = text.size();
        std::string line = strip(text.substr(pos, end - pos));
        pos = end + 1;
        size_t eq = line.find('=');
        if (line.empty() || line[0] == ';' || line[0] == '#' || eq == std::string::npos) continue;
        out[lower(strip(line.substr(0, eq)))] = strip(line.substr(eq + 1));
    }
    return out;
}

// A peer-sent value made safe for the space-separated status line (no spaces, newlines or '=').
inline std::string clean_token(const std::string& value, size_t limit = 32) {
    std::string out;
    for (char c : value) {
        if (std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '.' || c == '-') out.push_back(c);
        if (out.size() == limit) break;
    }
    return out.empty() ? "?" : out;
}

inline const char* const SHARED_SETTINGS[] = {"coopenemyhealth", "coopenemyposture", "pvp", "pvpdamage",
                                              "pvpparryposture", "connect", "revive"};

inline bool is_shared_setting(const std::string& key) {
    return std::any_of(std::begin(SHARED_SETTINGS), std::end(SHARED_SETTINGS), [&](const char* k) { return key == k; });
}

// An IPv4 address and port (host byte order), or a SteamID64.
struct Addr {
    uint32_t ip = 0;
    uint16_t port = 0;
    uint64_t steam = 0;
    bool operator==(const Addr& o) const { return ip == o.ip && port == o.port && steam == o.steam; }
    bool operator!=(const Addr& o) const { return !(*this == o); }
};

class Link {
public:
    virtual ~Link() = default;
    virtual void send(const Addr& to, const std::string& data) = 0;
    virtual std::vector<std::pair<Addr, std::string>> receive() = 0;
    virtual bool wait(double seconds) = 0;                 // true once a packet may be waiting
    virtual std::vector<Addr> candidates() { return {}; }  // guests with no host yet ping these
    virtual std::string describe(const Addr& a) = 0;
    virtual std::string describe_self() = 0;
    virtual const char* via() = 0;
    // A peer's short name: what its files are called and what net_status.txt lists it as. A host has several
    // guests, and their addresses share a "127.0.0.1:" prefix, so the port alone tells them apart.
    virtual std::string key_name(const Addr& a) { return describe(a); }
    std::optional<Addr> peer;     // known up front (UDP guest, Steam guest given an id)
    std::optional<std::string> session;   // a stable name for a peer whose address changes (Steam); UDP leaves it empty
    long long filtered = 0;
};

class UdpLink : public Link {
public:
    UdpLink(const std::string& role, const std::string& peer_host, int port, bool allow_any) : allow_any_(allow_any) {
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) throw std::runtime_error("Winsock didn't start");
        sock_ = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        if (sock_ == INVALID_SOCKET) throw std::runtime_error("couldn't open a UDP socket");
        u_long nonblocking = 1;
        ioctlsocket(sock_, FIONBIO, &nonblocking);
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
        addr.sin_port = htons(static_cast<u_short>(role == "host" ? port : 0));
        if (bind(sock_, reinterpret_cast<sockaddr*>(&addr), sizeof addr) != 0) {
            closesocket(sock_);
            throw std::runtime_error("couldn't use UDP port " + std::to_string(port) + " (error " +
                                     std::to_string(WSAGetLastError()) + ")");
        }
        if (role != "host") {
            // Resolved once (a Tailscale name works too): replies are matched against this exact address.
            addrinfo hints{};
            hints.ai_family = AF_INET;
            hints.ai_socktype = SOCK_DGRAM;
            addrinfo* found = nullptr;
            if (getaddrinfo(peer_host.c_str(), nullptr, &hints, &found) != 0 || !found) {
                closesocket(sock_);
                throw std::runtime_error("couldn't find the host address " + peer_host);
            }
            Addr a;
            a.ip = ntohl(reinterpret_cast<sockaddr_in*>(found->ai_addr)->sin_addr.s_addr);
            a.port = static_cast<uint16_t>(port);
            freeaddrinfo(found);
            peer = a;
        }
    }

    ~UdpLink() override {
        closesocket(sock_);
        WSACleanup();
    }

    void send(const Addr& to, const std::string& data) override {
        sockaddr_in addr{};
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(to.ip);
        addr.sin_port = htons(to.port);
        sendto(sock_, data.data(), static_cast<int>(data.size()), 0, reinterpret_cast<sockaddr*>(&addr), sizeof addr);
    }

    std::vector<std::pair<Addr, std::string>> receive() override {
        std::vector<std::pair<Addr, std::string>> out;
        static thread_local std::vector<char> buf(65536);
        for (int i = 0; i < MAX_PACKETS_PER_RECEIVE; i++) {
            sockaddr_in from{};
            int from_len = sizeof from;
            int n = recvfrom(sock_, buf.data(), static_cast<int>(buf.size()), 0, reinterpret_cast<sockaddr*>(&from), &from_len);
            if (n < 0) {
                int err = WSAGetLastError();
                // Windows reports ICMP "port unreachable" this way while the peer isn't running yet.
                if (err == WSAECONNRESET || err == WSAEMSGSIZE) continue;
                break;
            }
            Addr a;
            a.ip = ntohl(from.sin_addr.s_addr);
            a.port = ntohs(from.sin_port);
            if (peer && a != *peer) filtered++;      // a guest listens to its host's exact address and port only
            else if (!peer && !allow_any_ && !address_allowed(a.ip)) filtered++;
            else out.emplace_back(a, std::string(buf.data(), n));
        }
        return out;
    }

    bool wait(double seconds) override {
        fd_set read;
        FD_ZERO(&read);
        FD_SET(sock_, &read);
        timeval tv;
        tv.tv_sec = static_cast<long>(seconds);
        tv.tv_usec = static_cast<long>((seconds - tv.tv_sec) * 1e6);
        return select(0, &read, nullptr, nullptr, &tv) > 0;
    }

    std::string describe(const Addr& a) override {
        char s[32];
        std::snprintf(s, sizeof s, "%u.%u.%u.%u:%u", a.ip >> 24, (a.ip >> 16) & 255, (a.ip >> 8) & 255, a.ip & 255, a.port);
        return s;
    }

    std::string key_name(const Addr& a) override { return describe(a); }

    std::string describe_self() override {
        sockaddr_in me{};
        int len = sizeof me;
        getsockname(sock_, reinterpret_cast<sockaddr*>(&me), &len);
        return "UDP " + std::to_string(ntohs(me.sin_port));
    }

    const char* via() override { return "udp"; }

private:
    SOCKET sock_ = INVALID_SOCKET;
    bool allow_any_;
};

// One other relay, as this one knows it: a host keeps one per guest, a guest one per network (its host).
struct Peer {
    Addr addr;
    std::string key;               // the suffix of its files (the address it came from, cleaned)
    double last_heard = 0, last_hello = 0;
    std::optional<double> rtt_ms;
    std::string partner_version;
    std::vector<std::string> mismatch;
    std::map<std::string, long long> acked;   // our session -> highest event id this peer confirmed
    long long events_acked = 0;
    bool in_blanked = false;       // its snapshot file emptied because it went silent
    std::string in_player, in_enemies;
    double last_enemies = 0;
    bool enemies_sent = false;     // the last enemy packet had enemies: an empty list must follow them

    bool alive(double now) const { return now - last_heard <= PEER_TIMEOUT; }
};

class Relay {
public:
    Relay(std::string role, const std::wstring& dir, std::unique_ptr<Link> link, const std::string* secret,
          const Ini& ini, const std::string& version, std::function<void(const std::string&)> log,
          int max_players = 2)
        : role_(std::move(role)), dir_(dir), link_(std::move(link)), log_(std::move(log)),
          out_path_(dir + L"\\net_out.txt"), in_path_(dir + L"\\net_in.txt"),
          events_out_path_(dir + L"\\net_events_out.txt"), events_in_path_(dir + L"\\net_events_in.txt"),
          version_(clean_token(version)), max_players_(std::max(1, max_players)) {
        status_path = dir + L"\\net_status.txt";
        if (secret) auth_ = std::make_unique<Auth>(*secret, role_);
        for (const auto& [key, value] : ini)
            if (is_shared_setting(key)) settings_[key] = lower(value);
        if (link_->peer) peer_for(*link_->peer, monotonic());
        single_ = peers_.size() <= 1;
        for (auto& [key, peer] : peers_) inboxes_[key] = std::make_unique<EventInbox>(events_path(peer));
    }

    void tick(double now) {
        receive_all(now);
        for (auto& [key, peer] : peers_) {
            if (!peer.in_blanked && !peer.alive(now)) {
                // The peer is gone: don't leave its last snapshot for the mod to keep applying.
                if (write_atomic(snapshot_path(peer), "")) {
                    peer.in_player.clear();
                    peer.in_enemies.clear();
                    peer.in_blanked = true;
                }
            }
        }
        if (now - last_ping_ >= PING_EVERY) {
            if (peers_.empty() && role_ != "host") {
                for (const Addr& friend_id : link_->candidates()) send_raw(ping_message(now), &friend_id);
            } else {
                send_raw(ping_message(now));
            }
            last_ping_ = now;
        }
        for (auto& [key, peer] : peers_) {
            if (now - peer.last_hello >= HELLO_EVERY) {
                send_raw(hello_message(), &peer);
                peer.last_hello = now;
            }
        }
        // Resent if nothing went out since the last tick, so a dropped packet heals itself. wait() sends on change,
        // which is every tick while the mod runs: sending here as well doubled the traffic.
        if (monotonic() - last_state_ >= TICK) send_state();
    }

    // Sleep until the next tick, but handle incoming packets the moment they arrive, and send the mod's snapshot or
    // events the moment it writes them (checked every WATCH s) instead of on the next tick.
    void wait(double seconds) {
        const double deadline = monotonic() + seconds;
        while (true) {
            double remaining = deadline - monotonic();
            if (remaining <= 0) return;
            if (link_->wait(std::min(remaining, WATCH))) receive_all(monotonic());
            std::string sig = out_signature();
            if (sig != out_signature_) {
                out_signature_ = sig;
                send_state();
            }
        }
    }

    std::string status(double now) {
        bool any_up = std::any_of(peers_.begin(), peers_.end(), [&](const auto& kv) { return kv.second.alive(now); });
        bool connected = !peers_.empty() && (role_ == "host" || any_up);
        const Peer* first = peers_.empty() ? nullptr : &peers_.begin()->second;
        std::string peer = "-";
        if (first) {
            peer = link_->describe(first->addr);
            std::replace(peer.begin(), peer.end(), ' ', '_');
        }
        std::string rtt = rtt_text(first && first->rtt_ms ? first->rtt_ms : std::optional<double>{});
        std::string mismatch;
        if (first)
            for (const auto& k : first->mismatch) mismatch += (mismatch.empty() ? "" : ",") + k;
        // time= (wall clock) lets the mod tell a running relay from a stale status file before starting another.
        std::string line = "role=" + role_ + " via=" + link_->via() + " connected=" + (connected ? "yes" : "no") +
                           " peer=" + peer + " rtt_ms=" + rtt + " sent=" + std::to_string(sent_) +
                           " received=" + std::to_string(received_) + " filtered=" + std::to_string(link_->filtered) +
                           " rejected=" + std::to_string(rejected_) + " auth=" + (auth_ ? "on" : "off") +
                           " version=" + version_ +
                           " partner_version=" + (first && !first->partner_version.empty() ? first->partner_version : "-") +
                           " mismatch=" + (mismatch.empty() ? "-" : mismatch) + " events_acked=" +
                           std::to_string(first ? first->events_acked : 0) + " events_in=" +
                           std::to_string(inbox()->last_id) + " ";
        if (peers_.size() > 1 || !single_) {
            line += "peers=" + std::to_string(peers_.size()) + " max_players=" + std::to_string(max_players_) + " ";
            size_t n = 0;
            for (const auto& [key, p] : peers_)
                line += "peer" + std::to_string(++n) + "=" + key + "," + (p.alive(now) ? "up" : "gone") + "," +
                        rtt_text(p.rtt_ms) + " ";
        }
        return line + "time=" + std::to_string(static_cast<long long>(std::time(nullptr)));
    }

    std::string describe_self() { return link_->describe_self(); }

    std::wstring status_path;
    std::map<std::string, Peer> peers_;      // public for the tests: key -> peer, in the order they were heard

    // A sender over the limit that has been silent for a while loses its slot, and its snapshot goes.
    void prune(double now) {
        if (role_ != "host") return;
        for (auto it = peers_.begin(); it != peers_.end();) {
            if (now - it->second.last_heard > PRUNE_AFTER) {
                remove_quietly(snapshot_path(it->second));
                inboxes_.erase(it->first);
                it = peers_.erase(it);
            } else {
                ++it;
            }
        }
    }

private:
    static std::string rtt_text(const std::optional<double>& rtt) {
        if (!rtt) return "-";
        char s[32];
        std::snprintf(s, sizeof s, "%.0f", *rtt);
        return s;
    }

    static std::string ping_message(double now) {
        char msg[80];
        std::snprintf(msg, sizeof msg, "{\"t\":\"ping\",\"ts\":%.17g,\"v\":%d}", now, PROTOCOL);
        return msg;
    }

    std::string hello_message() {
        std::string msg = "{\"t\":\"hello\",\"ver\":";
        json::append_string(msg, version_);
        msg += ",\"cfg\":{";
        bool first = true;
        for (const auto& [key, value] : settings_) {
            if (!first) msg.push_back(',');
            first = false;
            json::append_string(msg, key);
            msg.push_back(':');
            json::append_string(msg, value);
        }
        return msg + "},\"v\":" + std::to_string(PROTOCOL) + "}";
    }

    // --- peers ------------------------------------------------------------

    Peer* find(const std::string& via, const Addr& addr) {
        for (auto& [key, peer] : peers_)
            if ((!via.empty() && key == via) || peer.addr == addr) return &peer;
        return nullptr;
    }

    // The peer at that address; a host takes it on (up to MaxPlayers) the first time it hears from it.
    Peer* peer_for(const Addr& addr, double now, const std::string* via = nullptr) {
        if (Peer* found = find(via ? *via : std::string(), addr)) {
            found->addr = addr;
            found->last_heard = now;
            return found;
        }
        if (role_ != "host" && !peers_.empty()) return nullptr;   // a guest answers one host per network
        std::string ident = via ? *via : link_->key_name(addr);
        std::string key = clean_token(ident, 40);
        auto it = peers_.find(key);
        if (it == peers_.end()) {
            Peer fresh;
            fresh.key = key;
            it = peers_.emplace(key, std::move(fresh)).first;
            inboxes_[key] = std::make_unique<EventInbox>(events_path(it->second));
        }
        it->second.addr = addr;
        it->second.last_heard = now;
        return &it->second;
    }

    EventInbox* inbox() {
        static EventInbox none{std::wstring()};
        if (peers_.empty()) return &none;
        return inboxes_[peers_.begin()->first].get();
    }

    std::wstring snapshot_path(const Peer& peer) {
        return single_ ? in_path_ : dir_ + L"\\net_in_" + widen(peer.key) + L".txt";
    }

    std::wstring events_path(const Peer& peer) {
        return single_ ? events_in_path_ : dir_ + L"\\net_events_in_" + widen(peer.key) + L".txt";
    }

    // One peer: 1.4.1's files. More than one: one pair per peer, and the peer that had net_in.txt moves over.
    void sync_single() {
        bool want = peers_.size() <= 1;
        if (want == single_) return;
        single_ = want;
        // Whoever already had a snapshot gets it written under the new name, then the inboxes follow the names.
        for (auto& [key, peer] : peers_) {
            if (peer.in_player.empty() && peer.in_enemies.empty()) continue;
            write_atomic(snapshot_path(peer), peer.in_player + peer.in_enemies);
        }
        if (!single_) {
            remove_quietly(in_path_);
            remove_quietly(events_in_path_);
        }
        for (auto& [key, peer] : peers_) inboxes_[key] = std::make_unique<EventInbox>(events_path(peer));
    }

    // --- sending ----------------------------------------------------------

    // To one address, to one peer, or (neither) to everyone: a host broadcasts what it reads and unicasts replies.
    void send_raw(const std::string& msg, const Addr* to = nullptr) {
        if (to) {
            link_->send(*to, auth_ ? auth_->seal(msg) : msg);
            sent_++;
            return;
        }
        for (auto& [key, peer] : peers_) send_raw(msg, &peer.addr);
    }

    void send_raw(const std::string& msg, Peer* to) {
        if (to) send_raw(msg, &to->addr);
    }

    void send_snapshot_part(const char* key, const std::string& text) {
        std::string msg = std::string("{\"t\":\"state\",\"") + key + "\":";
        json::append_string(msg, text);
        send_raw(msg + ",\"v\":" + std::to_string(PROTOCOL) + "}");
    }

    void send_state() {
        const double now = monotonic();
        last_state_ = now;
        // Events first: a dead enemy's "K" should arrive before the enemy list that no longer has it.
        ParsedEvents parsed = parse_events(read_complete_lines(events_out_path_));
        if (parsed.session) {
            // Each peer confirms on its own: one slow guest must not hold back the others.
            std::map<std::string, std::string> pending_for;
            for (auto& [key, peer] : peers_) {
                auto it = peer.acked.find(*parsed.session);
                long long acked = it == peer.acked.end() ? 0 : it->second;
                std::string lines;
                size_t count = 0, size = 0;
                for (const auto& [id, line] : parsed.events) {
                    if (id <= acked) continue;
                    if (count && (count == MAX_EVENTS_PER_PACKET || size + line.size() > MAX_EVENT_BYTES)) break;
                    if (count++) lines.push_back(',');
                    json::append_string(lines, line);
                    size += line.size();
                }
                pending_for[key] = lines;
                peer.events_acked = acked;
            }
            // The session is repeated even with nothing pending, so the peer's inbox follows restarts.
            bool repeat = now - last_session_ >= SESSION_EVERY;
            for (auto& [key, peer] : peers_) {
                if (!repeat && pending_for[key].empty()) continue;
                std::string msg = "{\"t\":\"state\",\"e\":{\"sid\":";
                json::append_string(msg, *parsed.session);
                send_raw(msg + ",\"l\":[" + pending_for[key] + "]},\"v\":" + std::to_string(PROTOCOL) + "}",
                         &peer.addr);
            }
            if (repeat) last_session_ = now;
        }
        std::string snapshot = read_text(out_path_);
        if (!strip(snapshot).empty()) {
            if (snapshot.size() > MAX_SNAPSHOT_BYTES) snapshot.resize(MAX_SNAPSHOT_BYTES);
            std::string player, enemies;
            for (size_t at = 0; at < snapshot.size();) {
                size_t end = snapshot.find('\n', at);
                end = end == std::string::npos ? snapshot.size() : end + 1;
                (snapshot.compare(at, 2, "E ") == 0 ? enemies : player).append(snapshot, at, end - at);
                at = end;
            }
            send_snapshot_part("s", player);
            bool any_sent = std::any_of(peers_.begin(), peers_.end(), [](const auto& kv) { return kv.second.enemies_sent; });
            double latest = 0;
            for (const auto& [key, peer] : peers_) latest = std::max(latest, peer.last_enemies);
            if ((!enemies.empty() || any_sent) && now - latest >= ENEMY_EVERY) {
                send_snapshot_part("n", enemies);
                for (auto& [key, peer] : peers_) {
                    peer.last_enemies = now;
                    peer.enemies_sent = !enemies.empty();
                }
            }
        }
    }

    // --- receiving --------------------------------------------------------

    void receive_all(double now) {
        for (auto& [addr, packet] : link_->receive()) {
            // Checked before anything else (before a host takes a sender as a peer): with a secret only validly
            // signed packets count; without one, signed packets mean the peer set a secret we don't have.
            std::string data;
            if (auth_) {
                auto opened = auth_->open(packet);
                if (!opened) {
                    rejected_++;
                    continue;
                }
                data = std::move(*opened);
            } else if (packet.compare(0, 4, Auth::MAGIC, 4) == 0) {
                rejected_++;
                continue;
            } else {
                data = std::move(packet);
            }
            json::Value msg;
            if (!json::Parser(data).parse(msg) || msg.type != json::Value::Object) continue;
            const json::Value* v = msg.get("v");
            if (!v || v->type != json::Value::Number || v->number != PROTOCOL) continue;
            const std::string* kind = msg.get_string("t");
            std::string via = link_->session ? *link_->session : std::string();
            Peer* peer = nullptr;
            if (Peer* known = find(via, addr)) {
                known->last_heard = now;
                peer = known;
            } else if (role_ == "host") {
                // MaxPlayers counts the host too: a host with 2 takes one guest, not two (the same limit the
                // Python relay applies). Only live peers take a slot, so a guest whose relay restarted gets back in
                // without waiting out PRUNE_AFTER.
                size_t live = 0;
                for (const auto& [key, p] : peers_)
                    if (p.alive(now)) ++live;
                if (live >= static_cast<size_t>(std::max(0, max_players_ - 1))) {
                    refused_++;
                    continue;
                }
                peer = peer_for(addr, now, via.empty() ? nullptr : &via);
                if (peer) log_("peer connected: " + link_->describe(addr));
            } else {
                // A guest still looking for its host takes the first friend that answers a ping; it never answers
                // other guests' pings itself.
                if (!peers_.empty() || !kind || *kind != "pong") continue;
                peer = peer_for(addr, now, via.empty() ? nullptr : &via);
                if (peer) log_("found the host: " + link_->describe(addr));
            }
            if (!peer) continue;
            received_++;
            sync_single();
            if (!kind) continue;
            if (*kind == "ping") {
                const json::Value* ts = msg.get("ts");
                char reply[80];
                if (ts && ts->type == json::Value::Number && std::isfinite(ts->number))
                    std::snprintf(reply, sizeof reply, "{\"t\":\"pong\",\"ts\":%.17g,\"v\":%d}", ts->number, PROTOCOL);
                else
                    std::snprintf(reply, sizeof reply, "{\"t\":\"pong\",\"ts\":null,\"v\":%d}", PROTOCOL);
                send_raw(reply, peer);
            } else if (*kind == "pong") {
                const json::Value* ts = msg.get("ts");
                if (ts && ts->type == json::Value::Number && std::fabs(ts->number) < 1e12)
                    peer->rtt_ms = (now - ts->number) * 1000.0;
            } else if (*kind == "state") {
                const std::string* s = msg.get_string("s");
                const std::string* n = msg.get_string("n");
                if (s || n) {
                    if (s) peer->in_player = *s;
                    if (n) peer->in_enemies = *n;
                    peer->in_blanked = false;
                    write_atomic(snapshot_path(*peer), peer->in_player + peer->in_enemies);
                    if (!single_) keep_snapshots();
                }
                const json::Value* ev = msg.get("e");
                const std::string* sid = ev && ev->type == json::Value::Object ? ev->get_string("sid") : nullptr;
                const json::Value* lines = ev && ev->type == json::Value::Object ? ev->get("l") : nullptr;
                if (sid && lines && lines->type == json::Value::Array) {
                    std::string text;
                    for (const auto& line : lines->items)
                        if (line.type == json::Value::String) text += line.text + "\n";
                    long long last = inboxes_[peer->key]->accept(*sid, parse_events(text).events);
                    // Only the sender needs this: sent to it alone, never to the rest of the party.
                    std::string ack = "{\"t\":\"ack\",\"sid\":";
                    json::append_string(ack, *sid);
                    send_raw(ack + ",\"id\":" + std::to_string(last) + ",\"v\":" + std::to_string(PROTOCOL) + "}", peer);
                }
            } else if (*kind == "ack") {
                const std::string* sid = msg.get_string("sid");
                const json::Value* id = msg.get("id");
                if (sid && id && id->type == json::Value::Number && id->integer) {
                    // Taken as is, even when lower: a restarted peer relay starts its inbox over and acks 0, and
                    // only then do we resend the events it lost.
                    if (peer->acked.size() >= MAX_ACKED_SESSIONS && !peer->acked.count(*sid)) peer->acked.clear();
                    peer->acked[*sid] = static_cast<long long>(id->number);
                }
            } else if (*kind == "hello") {
                const json::Value* cfg = msg.get("cfg");
                if (cfg && cfg->type == json::Value::Object) {
                    const std::string* ver = msg.get_string("ver");
                    peer->partner_version = clean_token(ver ? *ver : "");
                    peer->mismatch.clear();
                    for (const auto& [key, value] : settings_) {
                        const json::Value* theirs = cfg->get(key.c_str());
                        if (theirs && theirs->type == json::Value::String && lower(clean_token(theirs->text)) != value)
                            peer->mismatch.push_back(key);
                    }
                }
            }
        }
    }

    // Delete the snapshot files of peers that are gone (and only those: the others are being written).
    void keep_snapshots() {
        std::set<std::string> keep;
        for (auto& [key, peer] : peers_)
            if (!peer.in_blanked) keep.insert(peer.key);
        WIN32_FIND_DATAW found;
        HANDLE h = FindFirstFileW((dir_ + L"\\net_in_*.txt").c_str(), &found);
        if (h == INVALID_HANDLE_VALUE) return;
        do {
            std::string name = narrow(found.cFileName);
            std::string key = name.substr(7, name.size() - 11);
            if (name == "net_in.txt" || keep.count(key)) continue;
            remove_quietly(dir_ + L"\\" + found.cFileName);
        } while (FindNextFileW(h, &found));
        FindClose(h);
    }

    std::string out_signature() {
        std::string sig;
        for (const std::wstring* path : {&out_path_, &events_out_path_}) {
            WIN32_FILE_ATTRIBUTE_DATA info;
            if (GetFileAttributesExW(path->c_str(), GetFileExInfoStandard, &info)) {
                sig.append(reinterpret_cast<const char*>(&info.ftLastWriteTime), sizeof info.ftLastWriteTime);
                sig.append(reinterpret_cast<const char*>(&info.nFileSizeLow), sizeof info.nFileSizeLow);
            }
            sig.push_back('|');
        }
        return sig;
    }

    std::string role_;
    std::wstring dir_;
    std::unique_ptr<Link> link_;
    std::function<void(const std::string&)> log_;
    std::wstring out_path_, in_path_, events_out_path_, events_in_path_;
    std::map<std::string, std::unique_ptr<EventInbox>> inboxes_;
    std::unique_ptr<Auth> auth_;
    std::map<std::string, std::string> settings_;
    std::string version_, out_signature_;
    int max_players_;
    bool single_ = true;
    long long rejected_ = 0, received_ = 0, sent_ = 0, refused_ = 0;
    double last_hello_ = 0, last_ping_ = 0;
    double last_state_ = 0, last_session_ = 0;
};

struct Options {
    std::string role;              // "host" or "client"
    std::wstring dir;              // the mod's files
    std::string peer;              // client: the host's address; Steam: a name or id, or nothing
    std::string transport = "udp";
    bool allow_any = false;
    std::wstring ini;
    std::string version = "?";
    int port = 47800;
    double seconds = 0;            // 0 = until the heartbeat stops
    std::wstring alive_file;
    double alive_timeout = ALIVE_TIMEOUT;
    int max_players = 0;           // 0 = PhantomPact.ini's MaxPlayers (the command line is for tests)
};

// The mod rewrites its heartbeat file (a unix time) every few seconds while the game runs. It truncates, then
// writes: an empty or unreadable file is a write in progress, not a stop.
inline bool game_alive(const std::wstring& path, double timeout) {
    std::string text = strip(read_text(path));
    char* end = nullptr;
    double beat = std::strtod(text.c_str(), &end);
    if (text.empty() || *end != '\0') return true;
    return wall_seconds() - beat <= timeout;
}

std::unique_ptr<Link> make_steam_link(const std::string& role, const std::string& peer);

// Runs until the heartbeat stops. A failure leaves relay_error.txt next to the status, since nobody watches a console
// inside the game.
inline void run(Options o, const std::function<void(const std::string&)>& log) {
    const std::wstring status_path = o.dir + L"\\net_status.txt";
    timeBeginPeriod(1);    // Windows sleeps in ~15.6 ms steps by default, too coarse for WATCH
    try {
        Ini ini = o.ini.empty() ? Ini{} : read_ini(o.ini);
        auto any = ini.find("allowanyaddress");
        if (any != ini.end()) {
            std::string v = lower(any->second);
            // A virtual LAN with unusual addresses (UU Accelerator's multiplayer, ZeroTier...): the player opened it.
            if (v == "on" || v == "yes" || v == "true" || v == "1") o.allow_any = true;
        }
        std::string secret;
        if (auto it = ini.find("secret"); it != ini.end()) secret = it->second;
        std::string secret_lower = lower(secret);
        bool signed_packets = !(secret_lower.rfind("put-", 0) == 0 || secret_lower.empty() || secret_lower == "off" ||
                                secret_lower == "none");
        std::unique_ptr<Link> link;
        if (o.transport == "steam") link = make_steam_link(o.role, o.peer);
        else link = std::make_unique<UdpLink>(o.role, o.peer, o.port, o.allow_any);
        int max_players = 2;     // MaxPlayers counts players, the host included: 2 = the old one host, one guest
        if (o.max_players > 0) max_players = o.max_players;
        if (auto it = ini.find("maxplayers"); it != ini.end() && o.max_players <= 0) {
            try {
                max_players = std::max(1, std::stoi(it->second));
            } catch (const std::exception&) {
            }
        }
        Relay relay(o.role, o.dir, std::move(link), signed_packets ? &secret : nullptr, ini, o.version, log,
                    max_players);
        log("PBZCoop relay " + o.role + " on " + relay.describe_self() + (signed_packets ? ", packets signed (Secret set)" : ""));
        const double start = monotonic();
        double last_status = 0;
        while (true) {
            double now = monotonic();
            relay.tick(now);
            relay.prune(now);
            if (now - last_status >= 1.0) {
                std::string line = relay.status(now);
                write_atomic(status_path, line + "\n");
                log(line);
                last_status = now;
            }
            if (o.seconds > 0 && now - start >= o.seconds) break;
            if (!o.alive_file.empty() && !game_alive(o.alive_file, o.alive_timeout)) {
                log("the game's heartbeat stopped: game closed, relay exiting");
                break;
            }
            relay.wait(TICK);
        }
    } catch (const std::exception& e) {
        write_atomic(o.dir + L"\\relay_error.txt", std::string(e.what()) + "\n");
        log(std::string("relay failed: ") + e.what());
    }
    timeEndPeriod(1);
    write_atomic(status_path, "role=" + o.role + " connected=no stopped=yes\n");
}

}  // namespace relay
