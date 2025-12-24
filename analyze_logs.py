#!/usr/bin/env python3
"""Analyze lb.log to understand request timing patterns and TLS/HTTP2 lifecycle."""

import re
import sys
from collections import defaultdict

def parse_logs(filename):
    requests = defaultdict(dict)
    events = []  # (timestamp, event_type, details)

    # Request patterns
    start_pat = re.compile(r'\[\+ *(\d+)ms\].*\[REQ (\d+)\] START')
    responded_pat = re.compile(r'\[\+ *(\d+)ms\].*\[REQ (\d+)\] => \.responded')
    retry_pat = re.compile(r'\[\+ *(\d+)ms\].*\[REQ (\d+)\].*retrying fresh')
    pool_hit_pat = re.compile(r'\[\+ *(\d+)ms\].*\[REQ (\d+)\] H2 POOL HIT')
    pool_miss_pat = re.compile(r'\[\+ *(\d+)ms\].*\[REQ (\d+)\] POOL MISS')
    pool_add_pat = re.compile(r'\[\+ *(\d+)ms\].*\[REQ (\d+)\] H2 POOL ADD')
    fresh_h2_pat = re.compile(r'\[\+ *(\d+)ms\].*\[REQ (\d+)\] Creating fresh H2')
    fresh_added_pat = re.compile(r'\[\+ *(\d+)ms\].*\[REQ (\d+)\] Fresh H2 connection added')
    using_pooled_pat = re.compile(r'\[\+ *(\d+)ms\].*\[REQ (\d+)\] Using pooled H2')
    h2_response_pat = re.compile(r'\[\+ *(\d+)ms\].*\[REQ (\d+)\] HTTP/2 response: status=(\d+)')
    await_failed_pat = re.compile(r'\[\+ *(\d+)ms\].*\[REQ (\d+)\] H2 pooled await failed: error\.(\w+)')

    # Global events - GOAWAY
    goaway_pat = re.compile(r'\[\+ *(\d+)ms\].*GOAWAY received: last_stream_id=(\d+)')
    goaway_closing_pat = re.compile(r'\[\+ *(\d+)ms\].*GOAWAY received, connection closing')
    goaway_no_streams_pat = re.compile(r'\[\+ *(\d+)ms\].*GOAWAY: no remaining streams, exiting immediately')

    # TLS lifecycle
    tls_established_pat = re.compile(r'\[\+ *(\d+)ms\].*TLS established (\S+) \((\w+), (\w+)\)')
    tls_handshake_pat = re.compile(r'\[\+ *(\d+)ms\].*Starting TLS handshake with (\S+)')
    close_notify_pat = re.compile(r'\[\+ *(\d+)ms\].*Sending TLS close_notify')
    close_notify_sent_pat = re.compile(r'\[\+ *(\d+)ms\].*sent close_notify')
    close_notify_failed_pat = re.compile(r'\[\+ *(\d+)ms\].*TLS close_notify failed: (\S+)')
    tls_complete_pat = re.compile(r'\[\+ *(\d+)ms\].*TLS Handshake Complete')
    read_failed_pat = re.compile(r'\[\+ *(\d+)ms\].*TLS read error: error\.ReadFailed')

    # Connection lifecycle
    conn_closed_header_pat = re.compile(r'\[\+ *(\d+)ms\].*connection closed during header read')
    conn_dead_pat = re.compile(r'\[\+ *(\d+)ms\].*[Cc]onnection.*dead')
    conn_marked_dead_pat = re.compile(r'\[\+ *(\d+)ms\].*Connection marked dead')

    # Pool operations
    pool_reusing_pat = re.compile(r'\[\+ *(\d+)ms\].*Reusing connection: backend=(\d+) slot=(\d+)')
    pool_returning_pat = re.compile(r'\[\+ *(\d+)ms\].*Returning connection to pool: backend=(\d+)')
    pool_destroying_pat = re.compile(r'\[\+ *(\d+)ms\].*Destroying.*connection: backend=(\d+)')
    pool_stale_pat = re.compile(r'\[\+ *(\d+)ms\].*Connection stale, destroying')
    pool_created_pat = re.compile(r'\[\+ *(\d+)ms\].*Created fresh connection: backend=(\d+) slot=(\d+)')

    # Reader lifecycle
    reader_start_pat = re.compile(r'\[\+ *(\d+)ms\].*readerTask: started, active_streams=(\d+)')
    reader_exit_pat = re.compile(r'\[\+ *(\d+)ms\].*readerTask: exiting, shutdown_requested=(\w+)')
    reader_idle_pat = re.compile(r'\[\+ *(\d+)ms\].*Reader: idle timeout, continuing')
    spawn_reader_start_pat = re.compile(r'\[\+ *(\d+)ms\].*spawnReader: starting reader task')
    spawn_reader_already_pat = re.compile(r'\[\+ *(\d+)ms\].*spawnReader: already running')
    spawn_reader_dead_pat = re.compile(r'\[\+ *(\d+)ms\].*spawnReader: connection dead')

    # Async/timing
    io_async_pat = re.compile(r'\[\+ *(\d+)ms\].*Io\.async returned after (\d+)us \((\d+)ms\)')

    with open(filename) as f:
        for line in f:
            # Request events
            m = start_pat.search(line)
            if m:
                ts, req_id = int(m.group(1)), int(m.group(2))
                requests[req_id]['start'] = ts
                continue

            m = responded_pat.search(line)
            if m:
                ts, req_id = int(m.group(1)), int(m.group(2))
                requests[req_id]['responded'] = ts
                continue

            m = retry_pat.search(line)
            if m:
                ts, req_id = int(m.group(1)), int(m.group(2))
                requests[req_id]['retry'] = ts
                continue

            m = pool_hit_pat.search(line)
            if m:
                ts, req_id = int(m.group(1)), int(m.group(2))
                requests[req_id]['pool_hit'] = ts
                continue

            m = pool_miss_pat.search(line)
            if m:
                ts, req_id = int(m.group(1)), int(m.group(2))
                requests[req_id]['pool_miss'] = ts
                continue

            m = pool_add_pat.search(line)
            if m:
                ts, req_id = int(m.group(1)), int(m.group(2))
                requests[req_id]['pool_add'] = ts
                continue

            m = fresh_h2_pat.search(line)
            if m:
                ts, req_id = int(m.group(1)), int(m.group(2))
                requests[req_id]['fresh_h2'] = ts
                continue

            m = fresh_added_pat.search(line)
            if m:
                ts, req_id = int(m.group(1)), int(m.group(2))
                requests[req_id]['fresh_added'] = ts
                continue

            m = using_pooled_pat.search(line)
            if m:
                ts, req_id = int(m.group(1)), int(m.group(2))
                requests[req_id]['using_pooled'] = ts
                continue

            m = h2_response_pat.search(line)
            if m:
                ts, req_id, status = int(m.group(1)), int(m.group(2)), int(m.group(3))
                requests[req_id]['h2_response'] = ts
                requests[req_id]['status'] = status
                continue

            m = await_failed_pat.search(line)
            if m:
                ts, req_id, err = int(m.group(1)), int(m.group(2)), m.group(3)
                requests[req_id]['await_failed'] = ts
                requests[req_id]['await_error'] = err
                continue

            # Global events
            m = goaway_pat.search(line)
            if m:
                ts, last_stream = int(m.group(1)), int(m.group(2))
                events.append((ts, 'GOAWAY', f'last_stream_id={last_stream}'))
                continue

            m = tls_complete_pat.search(line)
            if m:
                ts = int(m.group(1))
                events.append((ts, 'TLS_COMPLETE', ''))
                continue

            m = read_failed_pat.search(line)
            if m:
                ts = int(m.group(1))
                events.append((ts, 'READ_FAILED', ''))
                continue

            m = io_async_pat.search(line)
            if m:
                ts, us, ms = int(m.group(1)), int(m.group(2)), int(m.group(3))
                if ms >= 1000:  # Only log slow Io.async (>1s)
                    events.append((ts, 'IO_ASYNC_SLOW', f'{ms}ms'))

            m = reader_exit_pat.search(line)
            if m:
                ts = int(m.group(1))
                events.append((ts, 'READER_EXIT', ''))

            m = goaway_closing_pat.search(line)
            if m:
                ts = int(m.group(1))
                events.append((ts, 'GOAWAY_FASTPATH', ''))

            m = spawn_reader_dead_pat.search(line)
            if m:
                ts = int(m.group(1))
                events.append((ts, 'SPAWN_READER_DEAD', ''))

            m = reader_start_pat.search(line)
            if m:
                ts, streams = int(m.group(1)), int(m.group(2))
                events.append((ts, 'READER_START', f'streams={streams}'))

            m = spawn_reader_start_pat.search(line)
            if m:
                ts = int(m.group(1))
                events.append((ts, 'SPAWN_READER_START', ''))

            m = spawn_reader_already_pat.search(line)
            if m:
                ts = int(m.group(1))
                events.append((ts, 'SPAWN_READER_ALREADY', ''))

            # TLS lifecycle
            m = tls_established_pat.search(line)
            if m:
                ts, host, cipher, proto = int(m.group(1)), m.group(2), m.group(3), m.group(4)
                events.append((ts, 'TLS_ESTABLISHED', f'{host} ({proto})'))

            m = tls_handshake_pat.search(line)
            if m:
                ts, host = int(m.group(1)), m.group(2)
                events.append((ts, 'TLS_HANDSHAKE_START', host))

            m = close_notify_pat.search(line)
            if m:
                ts = int(m.group(1))
                events.append((ts, 'CLOSE_NOTIFY_SENDING', ''))

            m = close_notify_sent_pat.search(line)
            if m:
                ts = int(m.group(1))
                events.append((ts, 'CLOSE_NOTIFY_SENT', ''))

            m = close_notify_failed_pat.search(line)
            if m:
                ts, err = int(m.group(1)), m.group(2)
                events.append((ts, 'CLOSE_NOTIFY_FAILED', err))

            # Connection lifecycle
            m = conn_closed_header_pat.search(line)
            if m:
                ts = int(m.group(1))
                events.append((ts, 'CONN_CLOSED_HEADER', ''))

            m = conn_marked_dead_pat.search(line)
            if m:
                ts = int(m.group(1))
                events.append((ts, 'CONN_MARKED_DEAD', ''))

            # Pool operations
            m = pool_reusing_pat.search(line)
            if m:
                ts, backend, slot = int(m.group(1)), m.group(2), m.group(3)
                events.append((ts, 'POOL_REUSE', f'backend={backend} slot={slot}'))

            m = pool_returning_pat.search(line)
            if m:
                ts, backend = int(m.group(1)), m.group(2)
                events.append((ts, 'POOL_RETURN', f'backend={backend}'))

            m = pool_destroying_pat.search(line)
            if m:
                ts, backend = int(m.group(1)), m.group(2)
                events.append((ts, 'POOL_DESTROY', f'backend={backend}'))

            m = pool_stale_pat.search(line)
            if m:
                ts = int(m.group(1))
                events.append((ts, 'POOL_STALE', ''))

            m = pool_created_pat.search(line)
            if m:
                ts, backend, slot = int(m.group(1)), m.group(2), m.group(3)
                events.append((ts, 'POOL_CREATE', f'backend={backend} slot={slot}'))

            m = goaway_no_streams_pat.search(line)
            if m:
                ts = int(m.group(1))
                events.append((ts, 'GOAWAY_NO_STREAMS', ''))

            m = reader_idle_pat.search(line)
            if m:
                ts = int(m.group(1))
                events.append((ts, 'READER_IDLE', ''))

    return requests, events

def analyze(requests, events):
    # Calculate durations
    durations = []
    retried = []
    pool_hits = 0
    pool_misses = 0

    for req_id, data in requests.items():
        if 'start' in data and 'responded' in data:
            duration = data['responded'] - data['start']
            durations.append((req_id, duration, data))

            if 'retry' in data:
                retried.append((req_id, duration, data))

            if 'pool_hit' in data:
                pool_hits += 1
            if 'pool_miss' in data:
                pool_misses += 1

    # Sort by duration
    durations.sort(key=lambda x: x[1], reverse=True)

    print("=" * 80)
    print("TOP 20 SLOWEST REQUESTS")
    print("=" * 80)
    print(f"{'REQ':<8} {'Duration':>10} {'Start':>10} {'End':>10} {'Retry?':>8} {'Notes'}")
    print("-" * 80)

    for req_id, duration, data in durations[:20]:
        retry_str = "YES" if 'retry' in data else ""
        notes = []
        if 'pool_hit' in data:
            notes.append("pool_hit")
        if 'pool_miss' in data:
            notes.append("pool_miss")
        if 'fresh_h2' in data:
            notes.append(f"fresh@{data['fresh_h2']}ms")

        print(f"{req_id:<8} {duration:>10}ms {data['start']:>10}ms {data['responded']:>10}ms {retry_str:>8} {' '.join(notes)}")

    # Detailed timeline for retried requests
    print()
    print("=" * 80)
    print("RETRIED REQUESTS (detailed timeline)")
    print("=" * 80)

    for req_id, duration, data in sorted(retried, key=lambda x: x[0])[:10]:
        print(f"\nREQ {req_id}:")

        # Build timeline
        timeline = []
        if 'start' in data:
            timeline.append(('start', data['start']))
        if 'pool_miss' in data:
            timeline.append(('pool_miss', data['pool_miss']))
        if 'pool_add' in data:
            timeline.append(('pool_add', data['pool_add']))
        if 'using_pooled' in data:
            timeline.append(('using_pooled', data['using_pooled']))
        if 'await_failed' in data:
            timeline.append(('await_failed', data['await_failed']))
        if 'retry' in data:
            timeline.append(('retry', data['retry']))
        if 'fresh_h2' in data:
            timeline.append(('fresh_h2', data['fresh_h2']))
        if 'fresh_added' in data:
            timeline.append(('fresh_added', data['fresh_added']))
        if 'h2_response' in data:
            timeline.append(('h2_response', data['h2_response']))
        if 'responded' in data:
            timeline.append(('responded', data['responded']))

        timeline.sort(key=lambda x: x[1])

        prev_ts = None
        for event, ts in timeline:
            delta = f"+{ts - prev_ts}ms" if prev_ts else ""
            print(f"  {ts:>8}ms  {event:<15} {delta}")
            prev_ts = ts

        print(f"  {'TOTAL':>8}   {duration}ms")

        # Find closest GOAWAY before await_failed
        if 'await_failed' in data:
            await_ts = data['await_failed']
            goaway_times = [ts for ts, evt, _ in events if evt == 'GOAWAY' and ts < await_ts]
            if goaway_times:
                closest_goaway = max(goaway_times)
                gap = await_ts - closest_goaway
                print(f"  Gap from last GOAWAY to await_failed: {gap}ms")

    # GOAWAY vs Retry correlation
    print()
    print("=" * 80)
    print("GOAWAY → RETRY CORRELATION")
    print("=" * 80)

    goaway_times = sorted([ts for ts, evt, _ in events if evt == 'GOAWAY'])
    retry_times = sorted([data['retry'] for _, _, data in retried if 'retry' in data])

    if goaway_times and retry_times:
        print(f"GOAWAY events: {len(goaway_times)}")
        print(f"Retry events:  {len(retry_times)}")

        # For each retry, find time since last GOAWAY
        gaps = []
        for retry_ts in retry_times:
            prior_goaways = [g for g in goaway_times if g < retry_ts]
            if prior_goaways:
                gap = retry_ts - max(prior_goaways)
                gaps.append(gap)

        if gaps:
            print(f"\nTime from GOAWAY to retry detection:")
            print(f"  Min:  {min(gaps)}ms")
            print(f"  Max:  {max(gaps)}ms")
            print(f"  Avg:  {sum(gaps) / len(gaps):.0f}ms")

            # Histogram
            buckets = defaultdict(int)
            for g in gaps:
                bucket = f"{g // 500 * 500}-{g // 500 * 500 + 500}ms"
                buckets[bucket] += 1
            print(f"\n  Distribution:")
            for bucket in sorted(buckets.keys(), key=lambda x: int(x.split('-')[0])):
                print(f"    {bucket}: {buckets[bucket]}")

    # Time breakdown for retried requests
    print()
    print("=" * 80)
    print("TIMING BREAKDOWN FOR RETRIED REQUESTS")
    print("=" * 80)

    detect_times = []
    fresh_times = []

    for req_id, duration, data in retried:
        if 'start' in data and 'retry' in data:
            detect_times.append(data['retry'] - data['start'])
        if 'retry' in data and 'responded' in data:
            fresh_times.append(data['responded'] - data['retry'])

    if detect_times:
        print(f"\nDead connection detection time (start → retry):")
        print(f"  Min:  {min(detect_times)}ms")
        print(f"  Max:  {max(detect_times)}ms")
        print(f"  Avg:  {sum(detect_times) / len(detect_times):.0f}ms")

    if fresh_times:
        print(f"\nFresh connection time (retry → responded):")
        print(f"  Min:  {min(fresh_times)}ms")
        print(f"  Max:  {max(fresh_times)}ms")
        print(f"  Avg:  {sum(fresh_times) / len(fresh_times):.0f}ms")

    # Show GOAWAY timeline
    goaways = [(ts, details) for ts, evt, details in events if evt == 'GOAWAY']
    if goaways:
        print()
        print("=" * 80)
        print(f"GOAWAY EVENTS ({len(goaways)} total)")
        print("=" * 80)
        if len(goaways) <= 20:
            prev = None
            for ts, details in goaways:
                delta = f"+{ts - prev}ms" if prev else ""
                print(f"  +{ts}ms {delta:>12} {details}")
                prev = ts
        else:
            print(f"  First: +{goaways[0][0]}ms")
            print(f"  Last:  +{goaways[-1][0]}ms")
            intervals = [goaways[i+1][0] - goaways[i][0] for i in range(len(goaways)-1)]
            if intervals:
                print(f"  Avg interval: {sum(intervals) / len(intervals):.0f}ms")

    # Show slow Io.async events
    slow_io = [(ts, details) for ts, evt, details in events if evt == 'IO_ASYNC_SLOW']
    if slow_io:
        print()
        print("=" * 80)
        print(f"SLOW IO.ASYNC EVENTS (>1s) - {len(slow_io)} total")
        print("=" * 80)
        by_duration = defaultdict(list)
        for ts, details in slow_io:
            ms = int(details.replace('ms', ''))
            bucket = f"{(ms // 1000)}s"
            by_duration[bucket].append(ts)
        for bucket in sorted(by_duration.keys()):
            print(f"  {bucket}: {len(by_duration[bucket])} events")

    # Show GOAWAY fast-path detections
    goaway_fastpath = [ts for ts, evt, _ in events if evt == 'GOAWAY_FASTPATH']
    spawn_dead = [ts for ts, evt, _ in events if evt == 'SPAWN_READER_DEAD']
    if goaway_fastpath or spawn_dead:
        print()
        print("=" * 80)
        print("GOAWAY FAST-PATH DETECTION")
        print("=" * 80)
        print(f"  GOAWAY fast-path hits:     {len(goaway_fastpath)}")
        print(f"  spawnReader dead hits:     {len(spawn_dead)}")
        print(f"  Slow Io.async (timeouts):  {len(slow_io)}")
        if goaway_fastpath or spawn_dead:
            total_fast = len(goaway_fastpath) + len(spawn_dead)
            total_slow = len(slow_io)
            if total_fast + total_slow > 0:
                pct = 100 * total_fast / (total_fast + total_slow)
                print(f"  Fast-path ratio:           {pct:.1f}%")

    # Reader lifecycle analysis
    reader_starts = [(ts, d) for ts, evt, d in events if evt == 'READER_START']
    reader_exits = [ts for ts, evt, _ in events if evt == 'READER_EXIT']
    spawn_starts = [ts for ts, evt, _ in events if evt == 'SPAWN_READER_START']
    spawn_already = [ts for ts, evt, _ in events if evt == 'SPAWN_READER_ALREADY']

    print()
    print("=" * 80)
    print("READER LIFECYCLE")
    print("=" * 80)
    print(f"  Reader started:            {len(reader_starts)}")
    print(f"  Reader exited:             {len(reader_exits)}")
    print(f"  spawnReader (new):         {len(spawn_starts)}")
    print(f"  spawnReader (already):     {len(spawn_already)}")

    if reader_starts and reader_exits:
        # Calculate reader lifetimes
        starts = sorted([ts for ts, _ in reader_starts])
        exits = sorted(reader_exits)

        # Match starts with exits (approximate)
        if len(starts) == len(exits):
            lifetimes = [e - s for s, e in zip(starts, exits)]
            print(f"\n  Reader lifetime:")
            print(f"    Min:  {min(lifetimes)}ms")
            print(f"    Max:  {max(lifetimes)}ms")
            print(f"    Avg:  {sum(lifetimes) / len(lifetimes):.0f}ms")

    # Show timeline of reader events around retries
    if retried and reader_exits:
        print(f"\n  Reader exits near retries:")
        for req_id, duration, data in sorted(retried, key=lambda x: x[0])[:5]:
            if 'retry' not in data:
                continue
            retry_ts = data['retry']
            # Find closest reader exit before retry
            prior_exits = [ts for ts in reader_exits if ts <= retry_ts]
            if prior_exits:
                closest = max(prior_exits)
                gap = retry_ts - closest
                print(f"    REQ {req_id}: reader exit at {closest}ms, retry at {retry_ts}ms (gap: {gap}ms)")

    # NEW: Analyze success path (retry vs direct)
    print()
    print("=" * 80)
    print("SUCCESS PATH ANALYSIS")
    print("=" * 80)

    direct_success = 0
    retry_success = 0
    first_use_fail = 0  # pool_add + using_pooled but then retry

    for req_id, data in requests.items():
        has_response = 'h2_response' in data or 'responded' in data
        had_retry = 'retry' in data
        was_pool_add = 'pool_add' in data
        was_using_pooled = 'using_pooled' in data

        if has_response:
            if had_retry:
                retry_success += 1
                if was_pool_add:
                    first_use_fail += 1
            else:
                direct_success += 1

    print(f"Direct success (no retry):    {direct_success}")
    print(f"Success after retry:          {retry_success}")
    print(f"First-use failures:           {first_use_fail} (pool_add → using_pooled → retry)")

    if direct_success + retry_success > 0:
        retry_pct = 100 * retry_success / (direct_success + retry_success)
        print(f"Retry rate:                   {retry_pct:.2f}%")

    # Analyze pool_add outcomes
    pool_add_requests = [(rid, data) for rid, data in requests.items() if 'pool_add' in data]
    pool_add_success = sum(1 for rid, data in pool_add_requests if 'responded' in data and 'retry' not in data)
    pool_add_retry = sum(1 for rid, data in pool_add_requests if 'retry' in data)

    print(f"\nNew connection (pool_add) outcomes:")
    print(f"  Total pool_add:             {len(pool_add_requests)}")
    print(f"  Success on first try:       {pool_add_success}")
    print(f"  Required retry:             {pool_add_retry}")
    if len(pool_add_requests) > 0:
        fail_pct = 100 * pool_add_retry / len(pool_add_requests)
        print(f"  First-use failure rate:     {fail_pct:.1f}%")

    # POOL CREATOR VS POOL USER ANALYSIS
    print()
    print("=" * 80)
    print("POOL CREATOR VS POOL USER ANALYSIS")
    print("=" * 80)

    # Find requests that did pool_add and their response times
    pool_creators = []
    for req_id, data in requests.items():
        if 'pool_add' in data:
            pool_creators.append((req_id, data))

    # Find first pool_hit requests right after pool_add (same connection reused)
    pool_users = []
    for req_id, data in requests.items():
        if 'pool_hit' in data and 'h2_response' in data:
            pool_users.append((req_id, data))

    if pool_creators:
        print(f"\nPool Creators (did pool_add):")
        print(f"  {'REQ':<8} {'add@':>10} {'resp@':>10} {'wait':>8} {'error':>20}")
        print(f"  {'-' * 60}")
        for req_id, data in sorted(pool_creators, key=lambda x: x[1].get('pool_add', 0))[:15]:
            add_ts = data.get('pool_add', 0)
            resp_ts = data.get('h2_response', data.get('responded', 0))
            wait = resp_ts - add_ts if resp_ts else 'N/A'
            error = data.get('await_error', 'none' if 'retry' not in data else 'retry needed')
            print(f"  {req_id:<8} {add_ts:>10} {resp_ts:>10} {wait:>8} {error:>20}")

    if pool_users:
        # Show first 15 pool users and their response times
        first_users = sorted(pool_users, key=lambda x: x[1].get('pool_hit', 0))[:15]
        print(f"\nPool Users (did pool_hit, first 15):")
        print(f"  {'REQ':<8} {'hit@':>10} {'resp@':>10} {'latency':>8}")
        print(f"  {'-' * 40}")
        for req_id, data in first_users:
            hit_ts = data.get('pool_hit', 0)
            resp_ts = data.get('h2_response', 0)
            latency = resp_ts - hit_ts if resp_ts else 'N/A'
            print(f"  {req_id:<8} {hit_ts:>10} {resp_ts:>10} {latency:>8}ms")

    # Compare timings
    if pool_creators and pool_users:
        creator_waits = []
        for req_id, data in pool_creators:
            if 'retry' not in data and 'h2_response' in data and 'pool_add' in data:
                creator_waits.append(data['h2_response'] - data['pool_add'])

        user_latencies = []
        for req_id, data in pool_users:
            if 'h2_response' in data and 'pool_hit' in data:
                user_latencies.append(data['h2_response'] - data['pool_hit'])

        print(f"\nLatency Comparison:")
        if creator_waits:
            print(f"  Pool creators (pool_add → h2_response, no retry):")
            print(f"    Count: {len(creator_waits)}, Avg: {sum(creator_waits)/len(creator_waits):.1f}ms")
        else:
            print(f"  Pool creators: ALL REQUIRED RETRY (0 direct success)")
        if user_latencies:
            print(f"  Pool users (pool_hit → h2_response):")
            print(f"    Count: {len(user_latencies)}, Avg: {sum(user_latencies)/len(user_latencies):.1f}ms")

    # Analyze timing gap between pool_add and using_pooled
    print()
    print("=" * 80)
    print("POOL_ADD TO AWAIT_FAILED GAP ANALYSIS")
    print("=" * 80)

    gaps = []
    for req_id, data in pool_creators:
        if 'pool_add' in data and 'await_failed' in data:
            gap = data['await_failed'] - data['pool_add']
            gaps.append((req_id, gap, data.get('await_error', 'unknown')))

    if gaps:
        print(f"\nTime from pool_add to await_failed (the 'stuck' time):")
        for req_id, gap, error in sorted(gaps, key=lambda x: x[1])[:10]:
            print(f"  REQ {req_id}: {gap}ms ({error})")
        print(f"\n  Min gap: {min(g[1] for g in gaps)}ms")
        print(f"  Max gap: {max(g[1] for g in gaps)}ms")
        print(f"  Avg gap: {sum(g[1] for g in gaps) / len(gaps):.0f}ms")

        # Bucket by error type
        by_error = defaultdict(list)
        for req_id, gap, error in gaps:
            by_error[error].append(gap)
        print(f"\n  By error type:")
        for error, err_gaps in by_error.items():
            print(f"    {error}: {len(err_gaps)} requests, avg gap: {sum(err_gaps)/len(err_gaps):.0f}ms")

    print()
    print("=" * 80)
    print("STATISTICS")
    print("=" * 80)

    all_durations = [d[1] for d in durations]
    if all_durations:
        print(f"Total requests:     {len(all_durations)}")
        print(f"Pool hits:          {pool_hits}")
        print(f"Pool misses:        {pool_misses}")
        print(f"Retried requests:   {len(retried)}")
        print(f"Min duration:       {min(all_durations)}ms")
        print(f"Max duration:       {max(all_durations)}ms")
        print(f"Avg duration:       {sum(all_durations) / len(all_durations):.1f}ms")

        sorted_dur = sorted(all_durations)
        p50 = sorted_dur[len(sorted_dur) // 2]
        p95 = sorted_dur[int(len(sorted_dur) * 0.95)]
        p99 = sorted_dur[int(len(sorted_dur) * 0.99)]
        print(f"P50:                {p50}ms")
        print(f"P95:                {p95}ms")
        print(f"P99:                {p99}ms")

        over_2s = [d for d in all_durations if d > 2000]
        print(f"\nRequests >2s (wrk timeout): {len(over_2s)}")
        if over_2s:
            print(f"  Min:      {min(over_2s)}ms")
            print(f"  Max:      {max(over_2s)}ms")
            buckets = defaultdict(int)
            for d in over_2s:
                bucket = f"{d // 1000}s-{d // 1000 + 1}s"
                buckets[bucket] += 1
            print("  By bucket:")
            for bucket in sorted(buckets.keys()):
                print(f"    {bucket}: {buckets[bucket]}")

    # TLS LIFECYCLE ANALYSIS
    print()
    print("=" * 80)
    print("TLS LIFECYCLE")
    print("=" * 80)

    tls_handshakes = [ts for ts, evt, _ in events if evt == 'TLS_HANDSHAKE_START']
    tls_established = [(ts, d) for ts, evt, d in events if evt == 'TLS_ESTABLISHED']
    close_notify_sending = [ts for ts, evt, _ in events if evt == 'CLOSE_NOTIFY_SENDING']
    close_notify_sent = [ts for ts, evt, _ in events if evt == 'CLOSE_NOTIFY_SENT']
    close_notify_failed = [(ts, d) for ts, evt, d in events if evt == 'CLOSE_NOTIFY_FAILED']

    print(f"  TLS handshakes started:    {len(tls_handshakes)}")
    print(f"  TLS connections established: {len(tls_established)}")
    print(f"  close_notify sending:      {len(close_notify_sending)}")
    print(f"  close_notify sent (reader): {len(close_notify_sent)}")
    print(f"  close_notify failed:       {len(close_notify_failed)}")

    if close_notify_failed:
        print(f"\n  close_notify failures:")
        for ts, err in close_notify_failed[:10]:
            print(f"    +{ts}ms: {err}")

    # Protocol breakdown
    h2_conns = [d for ts, d in tls_established if 'http2' in d.lower() or 'h2' in d.lower()]
    h1_conns = [d for ts, d in tls_established if 'http1' in d.lower() or 'http/1' in d.lower()]
    print(f"\n  Protocol breakdown:")
    print(f"    HTTP/2: {len(h2_conns)}")
    print(f"    HTTP/1.1: {len(h1_conns)}")

    # TLS handshake timing (if we have both start and established)
    if tls_handshakes and tls_established:
        # Match handshake starts with established (approximate)
        handshake_times = []
        starts = sorted(tls_handshakes)
        established = sorted([ts for ts, _ in tls_established])
        for i, start in enumerate(starts):
            # Find next established after this start
            later = [e for e in established if e > start]
            if later:
                handshake_times.append(later[0] - start)
        if handshake_times:
            print(f"\n  TLS handshake duration:")
            print(f"    Min: {min(handshake_times)}ms")
            print(f"    Max: {max(handshake_times)}ms")
            print(f"    Avg: {sum(handshake_times)/len(handshake_times):.1f}ms")

    # CONNECTION LIFECYCLE
    print()
    print("=" * 80)
    print("CONNECTION LIFECYCLE")
    print("=" * 80)

    conn_closed_header = [ts for ts, evt, _ in events if evt == 'CONN_CLOSED_HEADER']
    conn_marked_dead = [ts for ts, evt, _ in events if evt == 'CONN_MARKED_DEAD']
    reader_idles = [ts for ts, evt, _ in events if evt == 'READER_IDLE']

    print(f"  Connection closed during header read: {len(conn_closed_header)}")
    print(f"  Connection marked dead:               {len(conn_marked_dead)}")
    print(f"  Reader idle timeouts (continued):     {len(reader_idles)}")

    # Analyze GOAWAY → close_notify → socket close sequence
    goaway_events = [(ts, d) for ts, evt, d in events if evt == 'GOAWAY']
    if goaway_events and close_notify_sending:
        print(f"\n  GOAWAY → close_notify timing:")
        gaps = []
        for goaway_ts, _ in goaway_events:
            # Find close_notify within 100ms after GOAWAY
            later_cn = [ts for ts in close_notify_sending if goaway_ts <= ts <= goaway_ts + 100]
            if later_cn:
                gaps.append(later_cn[0] - goaway_ts)
        if gaps:
            print(f"    Matched GOAWAY→close_notify pairs: {len(gaps)}")
            print(f"    Gap min: {min(gaps)}ms, max: {max(gaps)}ms, avg: {sum(gaps)/len(gaps):.1f}ms")

    # POOL OPERATIONS
    print()
    print("=" * 80)
    print("POOL OPERATIONS")
    print("=" * 80)

    pool_creates = [(ts, d) for ts, evt, d in events if evt == 'POOL_CREATE']
    pool_reuses = [(ts, d) for ts, evt, d in events if evt == 'POOL_REUSE']
    pool_returns = [(ts, d) for ts, evt, d in events if evt == 'POOL_RETURN']
    pool_destroys = [(ts, d) for ts, evt, d in events if evt == 'POOL_DESTROY']
    pool_stales = [ts for ts, evt, _ in events if evt == 'POOL_STALE']

    print(f"  Fresh connections created: {len(pool_creates)}")
    print(f"  Connections reused:        {len(pool_reuses)}")
    print(f"  Connections returned:      {len(pool_returns)}")
    print(f"  Connections destroyed:     {len(pool_destroys)}")
    print(f"  Stale connections:         {len(pool_stales)}")

    if pool_reuses:
        reuse_ratio = len(pool_reuses) / (len(pool_creates) + len(pool_reuses)) * 100
        print(f"\n  Pool hit rate: {reuse_ratio:.1f}%")

    # Connection lifetime (create → destroy)
    if pool_creates and pool_destroys:
        create_times = sorted([ts for ts, _ in pool_creates])
        destroy_times = sorted([ts for ts, _ in pool_destroys])
        if len(create_times) == len(destroy_times):
            lifetimes = [d - c for c, d in zip(create_times, destroy_times)]
            if lifetimes and all(l >= 0 for l in lifetimes):
                print(f"\n  Connection lifetime:")
                print(f"    Min: {min(lifetimes)}ms")
                print(f"    Max: {max(lifetimes)}ms")
                print(f"    Avg: {sum(lifetimes)/len(lifetimes):.1f}ms")

    # SHUTDOWN SEQUENCE ANALYSIS
    print()
    print("=" * 80)
    print("SHUTDOWN SEQUENCE ANALYSIS")
    print("=" * 80)

    # Look for the pattern: GOAWAY → reader exit → close_notify → marked dead
    goaway_times = sorted([ts for ts, evt, _ in events if evt == 'GOAWAY'])
    reader_exits = [(ts, d) for ts, evt, d in events if evt == 'READER_EXIT']

    clean_shutdowns = 0
    unclean_shutdowns = 0
    for ts, details in reader_exits:
        if 'false' in details.lower():  # shutdown_requested=false
            unclean_shutdowns += 1
        else:
            clean_shutdowns += 1

    print(f"  Reader exits (clean shutdown):   {clean_shutdowns}")
    print(f"  Reader exits (unclean/GOAWAY):   {unclean_shutdowns}")

    # Check if close_notify follows unclean exits
    unclean_exit_times = [ts for ts, d in reader_exits if 'false' in d.lower()]
    close_notify_after_exit = 0
    for exit_ts in unclean_exit_times:
        # Look for close_notify within 10ms after exit
        if any(exit_ts <= cn_ts <= exit_ts + 10 for cn_ts in close_notify_sending):
            close_notify_after_exit += 1

    if unclean_shutdowns > 0:
        pct = 100 * close_notify_after_exit / unclean_shutdowns
        print(f"  close_notify after unclean exit: {close_notify_after_exit}/{unclean_shutdowns} ({pct:.1f}%)")

    # Timeline of last 10 shutdown sequences
    print(f"\n  Last 10 shutdown sequences:")
    shutdown_events = [(ts, evt, d) for ts, evt, d in events
                       if evt in ('GOAWAY', 'READER_EXIT', 'CLOSE_NOTIFY_SENDING',
                                  'CLOSE_NOTIFY_SENT', 'CONN_MARKED_DEAD', 'POOL_DESTROY',
                                  'CONN_CLOSED_HEADER')]
    shutdown_events.sort(key=lambda x: x[0])

    # Group by approximate time (within 50ms)
    if shutdown_events:
        groups = []
        current_group = [shutdown_events[0]]
        for evt in shutdown_events[1:]:
            if evt[0] - current_group[-1][0] < 50:
                current_group.append(evt)
            else:
                if len(current_group) >= 2:  # Only show multi-event sequences
                    groups.append(current_group)
                current_group = [evt]
        if len(current_group) >= 2:
            groups.append(current_group)

        for group in groups[-10:]:
            start_ts = group[0][0]
            print(f"\n    +{start_ts}ms:")
            for ts, evt, details in group:
                delta = ts - start_ts
                det_str = f" ({details})" if details else ""
                print(f"      +{delta:3}ms {evt}{det_str}")

if __name__ == '__main__':
    filename = sys.argv[1] if len(sys.argv) > 1 else 'lb.log'
    requests, events = parse_logs(filename)
    analyze(requests, events)
