import Toybox.Lang;
import Toybox.Math;

// Set detection and the wrist rep count from the accelerometer (HANDOFF.md §7, Garmin watch).
// 25 Hz samples arrive in one-second batches. A set starts when the standard deviation of the
// acceleration magnitude over the last 2 s rises above startStd with at least two direction
// reversals on the dominant axis, and ends when it stays below endStd for 4 s. Reps are the
// peaks of the dominant axis after a 5-sample moving average, with the same rule as reps.py:
// prominence of at least 35% of the range, at least 0.8 s apart. Thresholds come from the phone.
class SetDetector {
    const RATE = 25;                 // samples per second
    const WINDOW_SECONDS = 90;       // ring buffer length
    const START_WINDOW = 2 * RATE;   // 2 s
    const END_WINDOW = 4 * RATE;     // 4 s
    const MIN_REP_SAMPLES = 20;      // 0.8 s at 25 Hz
    const PROMINENCE = 0.35;

    var startStd as Float = 120.0;   // milli-g, from the phone's config message
    var endStd as Float = 40.0;

    private var _x as Array<Number>;
    private var _y as Array<Number>;
    private var _z as Array<Number>;
    private var _count as Number = 0;       // samples stored (up to the ring's size)
    private var _head as Number = 0;        // next write index
    private var _total as Number = 0;       // samples ever seen
    private var _active as Boolean = false;
    private var _setStartIndex as Number = 0;  // _total at the set's start
    private var _stillSamples as Number = 0;
    private var _lastMs as Number = 0;

    function initialize() {
        var n = WINDOW_SECONDS * RATE;
        _x = new [n] as Array<Number>;
        _y = new [n] as Array<Number>;
        _z = new [n] as Array<Number>;
        for (var i = 0; i < n; i++) { _x[i] = 0; _y[i] = 0; _z[i] = 0; }
    }

    function isActive() as Boolean { return _active; }

    // Feed one second of samples. Returns :start, :end or null. `nowMs` is the watch's uptime.
    function add(xs as Array<Number>, ys as Array<Number>, zs as Array<Number>, nowMs as Number) as Symbol? {
        var n = xs.size();
        var size = _x.size();
        for (var i = 0; i < n; i++) {
            _x[_head] = xs[i];
            _y[_head] = ys[i];
            _z[_head] = zs[i];
            _head = (_head + 1) % size;
            if (_count < size) { _count++; }
            _total++;
        }
        _lastMs = nowMs;
        if (_count < START_WINDOW) { return null; }

        if (_active) {
            var sd = _magnitudeStd(END_WINDOW);
            if (sd < endStd) {
                _stillSamples += n;
                if (_stillSamples >= END_WINDOW) {
                    _active = false;
                    _stillSamples = 0;
                    return :end;
                }
            } else {
                _stillSamples = 0;
            }
            return null;
        }
        var sd = _magnitudeStd(START_WINDOW);
        if (sd > startStd && _reversals(START_WINDOW) >= 2) {
            _active = true;
            _stillSamples = 0;
            _setStartIndex = _total - START_WINDOW;
            return :start;
        }
        return null;
    }

    // Uptime ms of the set's start and the end of the last movement (4 s before detection).
    function setStartMs() as Number { return _lastMs - (_total - _setStartIndex) * 1000 / RATE; }
    function setEndMs() as Number { return _lastMs - END_WINDOW * 1000 / RATE; }

    // Count the reps of the set that just ended: the samples from its start to its end.
    // Returns [reps, confidence].
    function countReps() as [Number, Float] {
        var length = _total - _setStartIndex - END_WINDOW;
        if (length < MIN_REP_SAMPLES) { return [0, 0.0]; }
        if (length > _count) { length = _count; }
        var offset = _count - length - END_WINDOW; // oldest index of the set within the ring
        if (offset < 0) { offset = 0; }
        var axis = _dominantAxis(offset, length);
        var series = new [length] as Array<Float>;
        for (var i = 0; i < length; i++) {
            series[i] = _sample(axis, offset + i).toFloat();
        }
        var smoothed = _movingAverage(series, 5);
        // Rest position: the median of the first and last 0.5 s; d = |smoothed - rest|.
        var edge = RATE / 2;
        var edges = [] as Array<Float>;
        for (var i = 0; i < edge && i < length; i++) { edges.add(smoothed[i]); }
        for (var i = length - edge; i < length; i++) { if (i >= 0) { edges.add(smoothed[i]); } }
        var rest = _median(edges);
        var d = new [length] as Array<Float>;
        var maxD = 0.0;
        for (var i = 0; i < length; i++) {
            d[i] = (smoothed[i] - rest).abs();
            if (d[i] > maxD) { maxD = d[i]; }
        }
        if (maxD < endStd) { return [0, 0.0]; }
        var peaks = _peaks(d, PROMINENCE * maxD, MIN_REP_SAMPLES);
        var reps = peaks.size();
        var confidence = 0.0;
        if (reps >= 2) {
            var intervals = new [reps - 1] as Array<Float>;
            var mean = 0.0;
            for (var i = 1; i < reps; i++) {
                intervals[i - 1] = (peaks[i] - peaks[i - 1]).toFloat();
                mean += intervals[i - 1];
            }
            mean /= intervals.size();
            var variance = 0.0;
            for (var i = 0; i < intervals.size(); i++) {
                variance += (intervals[i] - mean) * (intervals[i] - mean);
            }
            variance /= intervals.size();
            var cv = mean > 0 ? Math.sqrt(variance) / mean : 1.0;
            if (cv > 1.0) { cv = 1.0; }
            confidence = 1.0 - cv;
        } else if (reps == 1) {
            confidence = 0.5;
        }
        return [reps, confidence.toFloat()];
    }

    // --- internals ---

    private function _sample(axis as Number, i as Number) as Number {
        var idx = (_head - _count + i + _x.size()) % _x.size();
        if (axis == 0) { return _x[idx]; }
        if (axis == 1) { return _y[idx]; }
        return _z[idx];
    }

    private function _magnitudeStd(window as Number) as Float {
        if (window > _count) { window = _count; }
        var start = _count - window;
        var sum = 0.0;
        var mags = new [window] as Array<Float>;
        for (var i = 0; i < window; i++) {
            var x = _sample(0, start + i).toFloat();
            var y = _sample(1, start + i).toFloat();
            var z = _sample(2, start + i).toFloat();
            mags[i] = Math.sqrt(x * x + y * y + z * z);
            sum += mags[i];
        }
        var mean = sum / window;
        var variance = 0.0;
        for (var i = 0; i < window; i++) {
            variance += (mags[i] - mean) * (mags[i] - mean);
        }
        return Math.sqrt(variance / window).toFloat();
    }

    private function _dominantAxis(offset as Number, length as Number) as Number {
        var best = 0;
        var bestVar = -1.0;
        for (var axis = 0; axis < 3; axis++) {
            var mean = 0.0;
            for (var i = 0; i < length; i++) { mean += _sample(axis, offset + i); }
            mean /= length;
            var v = 0.0;
            for (var i = 0; i < length; i++) {
                var dlt = _sample(axis, offset + i) - mean;
                v += dlt * dlt;
            }
            if (v > bestVar) { bestVar = v; best = axis; }
        }
        return best;
    }

    private function _reversals(window as Number) as Number {
        if (window > _count) { window = _count; }
        var offset = _count - window;
        var axis = _dominantAxis(offset, window);
        var count = 0;
        var direction = 0;
        var anchor = _sample(axis, offset);
        for (var i = 1; i < window; i++) {
            var v = _sample(axis, offset + i);
            var delta = v - anchor;
            if (delta.abs() < 30) { continue; } // 30 mg of hysteresis against jitter
            var d = delta > 0 ? 1 : -1;
            if (direction != 0 && d != direction) { count++; }
            direction = d;
            anchor = v;
        }
        return count;
    }

    private function _movingAverage(series as Array<Float>, window as Number) as Array<Float> {
        var n = series.size();
        var out = new [n] as Array<Float>;
        var half = window / 2;
        for (var i = 0; i < n; i++) {
            var sum = 0.0;
            var cnt = 0;
            for (var k = i - half; k <= i + half; k++) {
                if (k >= 0 && k < n) { sum += series[k]; cnt++; }
            }
            out[i] = sum / cnt;
        }
        return out;
    }

    private function _median(values as Array<Float>) as Float {
        var n = values.size();
        if (n == 0) { return 0.0; }
        var sorted = values.slice(0, n) as Array<Float>;
        // insertion sort: the arrays are tiny
        for (var i = 1; i < n; i++) {
            var v = sorted[i];
            var j = i - 1;
            while (j >= 0 && sorted[j] > v) { sorted[j + 1] = sorted[j]; j--; }
            sorted[j + 1] = v;
        }
        if (n % 2 == 1) { return sorted[n / 2]; }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
    }

    // Local maxima with the distance filter (highest first), then the prominence filter: reps.py's rule.
    private function _peaks(d as Array<Float>, prominence as Float, distance as Number) as Array<Number> {
        var n = d.size();
        var maxima = [] as Array<Number>;
        var i = 1;
        while (i < n - 1) {
            if (d[i - 1] < d[i]) {
                var ahead = i + 1;
                while (ahead < n && d[ahead] == d[i]) { ahead++; }
                if (ahead < n && d[ahead] < d[i]) { maxima.add((i + ahead - 1) / 2); }
                i = ahead;
            } else {
                i++;
            }
        }
        var kept = [] as Array<Number>;
        // process by height, highest first
        var remaining = maxima.slice(0, maxima.size()) as Array<Number>;
        while (remaining.size() > 0) {
            var bestIdx = 0;
            for (var k = 1; k < remaining.size(); k++) {
                if (d[remaining[k]] > d[remaining[bestIdx]]) { bestIdx = k; }
            }
            var p = remaining[bestIdx];
            remaining.remove(p);
            var tooClose = false;
            for (var k = 0; k < kept.size(); k++) {
                if ((kept[k] - p).abs() < distance) { tooClose = true; break; }
            }
            if (tooClose) { continue; }
            if (_prominence(d, p) >= prominence) { kept.add(p); }
        }
        // sort ascending
        for (var a = 1; a < kept.size(); a++) {
            var v = kept[a];
            var b = a - 1;
            while (b >= 0 && kept[b] > v) { kept[b + 1] = kept[b]; b--; }
            kept[b + 1] = v;
        }
        return kept;
    }

    private function _prominence(d as Array<Float>, peak as Number) as Float {
        var h = d[peak];
        var left = h;
        var i = peak - 1;
        while (i >= 0 && d[i] <= h) { if (d[i] < left) { left = d[i]; } i--; }
        var right = h;
        i = peak + 1;
        while (i < d.size() && d[i] <= h) { if (d[i] < right) { right = d[i]; } i++; }
        var floor = left > right ? left : right;
        return h - floor;
    }
}
