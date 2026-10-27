import Toybox.Activity;
import Toybox.ActivityRecording;
import Toybox.Attention;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.Sensor;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

// The watch side of a session: sensors in, messages out and in, haptics, and the Garmin activity
// so heart rate and the workout still reach Garmin Connect (HANDOFF.md §7, Garmin watch).
//
// Watch → phone: {"t":"hello","v":1}, {"t":"setStart","at":ms}, {"t":"setEnd","startAt":ms,"at":ms,"reps":8,"conf":0.72},
//                {"t":"tap","a":"done"|"undo"|"skipRest"}, {"t":"pong","at":watchMs,"echo":phoneMs}
// Phone → watch: {"t":"config","startStd":…,"endStd":…}, {"t":"ping","at":phoneMs},
//                {"t":"target","ex":…,"load":…,"reps":…,"set":…}, {"t":"logged","reps":8,"src":"Watch"},
//                {"t":"rest","endsAt":ms}, {"t":"end"}
class WatchSession {
    const PROTOCOL_VERSION = 1;

    // What the view shows.
    var state as Symbol = :disconnected;   // :disconnected, :target, :inSet, :logged, :rest
    var exercise as String = "";
    var target as String = "";             // "225 × 8"
    var setLabel as String = "";           // "Set 3 of 4"
    var loggedText as String = "";         // "8 reps"
    var loggedSource as String = "";       // "Watch"
    var restEndsAtMs as Number = 0;        // in watch uptime
    var setStartedAtMs as Number = 0;
    var lastPhoneContactMs as Number = 0;
    var messagesSent as Number = 0;
    var lastError as String = "";

    private var _detector as SetDetector;
    private var _view as SetechoView?;
    private var _timer as Timer.Timer;
    private var _recording as ActivityRecording.Session?;
    private var _loggedUntilMs as Number = 0;
    private var _listener as CommListener;

    function initialize() {
        _detector = new SetDetector();
        _timer = new Timer.Timer();
        _listener = new CommListener(self);
    }

    function setView(view as SetechoView) as Void { _view = view; }

    function start() as Void {
        Communications.registerForPhoneAppMessages(method(:onPhoneMessage));
        var options = {
            :period => 1,
            :accelerometer => { :enabled => true, :sampleRate => SetDetector.RATE }
        };
        try {
            Sensor.registerSensorDataListener(method(:onSensorData), options);
        } catch (e) {
            lastError = "sensor";
        }
        _timer.start(method(:onTick), 1000, true);
        send({ "t" => "hello", "v" => PROTOCOL_VERSION });
    }

    function stop() as Void {
        _timer.stop();
        Sensor.unregisterSensorDataListener();
        Communications.registerForPhoneAppMessages(null);
        endRecording(true);
    }

    // --- motion ---

    function onSensorData(data as Sensor.SensorData) as Void {
        var accel = data.accelerometerData;
        if (accel == null) { return; }
        var now = System.getTimer();
        var event = _detector.add(accel.x, accel.y, accel.z, now);
        if (event == :start) {
            setStartedAtMs = _detector.setStartMs();
            state = :inSet;
            send({ "t" => "setStart", "at" => setStartedAtMs });
            refresh();
        } else if (event == :end) {
            var counted = _detector.countReps();
            var reps = counted[0];
            var conf = counted[1];
            var endMs = _detector.setEndMs();
            send({ "t" => "setEnd", "startAt" => setStartedAtMs, "at" => endMs, "reps" => reps, "conf" => conf });
            // Show the wrist count until the phone's "logged" message replaces it.
            showLogged(reps.toString() + " reps", "Watch");
        }
    }

    // --- input (DESIGN.md Watch) ---

    // A tap anywhere is "done": ends the set, or skips the rest.
    function onTap() as Void {
        if (state == :rest) {
            send({ "t" => "tap", "a" => "skipRest" });
            state = :target;
        } else {
            send({ "t" => "tap", "a" => "done" });
            if (state == :inSet) { state = :target; }
        }
        refresh();
    }

    function onUndo() as Void {
        send({ "t" => "tap", "a" => "undo" });
        buzz(false);
    }

    // --- messages ---

    function onPhoneMessage(msg as Communications.PhoneAppMessage) as Void {
        var data = msg.data;
        if (!(data instanceof Dictionary)) { return; }
        var d = data as Dictionary;
        lastPhoneContactMs = System.getTimer();
        var t = d["t"];
        if (t == null) { return; }
        if (t.equals("config")) {
            var s = d["startStd"];
            var e = d["endStd"];
            if (s != null) { _detector.startStd = (s as Numeric).toFloat(); }
            if (e != null) { _detector.endStd = (e as Numeric).toFloat(); }
            startRecording();
            if (state == :disconnected) { state = :target; }
        } else if (t.equals("ping")) {
            send({ "t" => "pong", "at" => System.getTimer(), "echo" => d["at"] });
            if (state == :disconnected) { state = :target; }
        } else if (t.equals("target")) {
            exercise = _str(d["ex"]);
            target = _str(d["load"]) + " × " + _str(d["reps"]);
            setLabel = "Set " + _str(d["set"]);
            if (state != :inSet && state != :rest) { state = :target; }
        } else if (t.equals("logged")) {
            showLogged(_str(d["reps"]) + " reps", _str(d["src"]));
        } else if (t.equals("rest")) {
            var ends = d["endsAt"];
            if (ends != null) { restEndsAtMs = (ends as Numeric).toNumber(); }
            state = :rest;
        } else if (t.equals("end")) {
            endRecording(false);
            state = :disconnected;
            exercise = "";
        }
        refresh();
    }

    function send(payload as Dictionary) as Void {
        messagesSent++;
        Communications.transmit(payload, null, _listener);
    }

    function onSendError() as Void {
        lastError = "send";
    }

    // --- feedback ---

    function showLogged(text as String, source as String) as Void {
        loggedText = text;
        loggedSource = source;
        state = :logged;
        _loggedUntilMs = System.getTimer() + 3000;
        buzz(false);
        refresh();
    }

    function buzz(long as Boolean) as Void {
        if (Attention has :vibrate) {
            var profile = new Attention.VibeProfile(60, long ? 700 : 200);
            Attention.vibrate([profile]);
        }
    }

    function onTick() as Void {
        var now = System.getTimer();
        if (state == :logged && now > _loggedUntilMs) {
            state = :target;
        }
        if (state == :rest && restEndsAtMs > 0 && now >= restEndsAtMs) {
            state = :target;
            restEndsAtMs = 0;
            buzz(true);
        }
        refresh();
    }

    function restRemainingSeconds() as Number {
        var left = (restEndsAtMs - System.getTimer()) / 1000;
        return left > 0 ? left : 0;
    }

    function setElapsedSeconds() as Number {
        return (System.getTimer() - setStartedAtMs) / 1000;
    }

    // --- Garmin activity: the session still reaches Garmin Connect as strength training ---

    private function startRecording() as Void {
        if (_recording != null) { return; }
        if (!(Toybox has :ActivityRecording)) { return; }
        try {
            _recording = ActivityRecording.createSession({
                :name => "Setecho",
                :sport => Activity.SPORT_TRAINING,
                :subSport => Activity.SUB_SPORT_STRENGTH_TRAINING
            });
            (_recording as ActivityRecording.Session).start();
        } catch (e) {
            lastError = "fit";
            _recording = null;
        }
    }

    private function endRecording(discard as Boolean) as Void {
        if (_recording == null) { return; }
        var rec = _recording as ActivityRecording.Session;
        try {
            if (rec.isRecording()) { rec.stop(); }
            if (discard) { rec.discard(); } else { rec.save(); }
        } catch (e) {
            lastError = "fit";
        }
        _recording = null;
    }

    private function refresh() as Void {
        WatchUi.requestUpdate();
    }

    private function _str(v) as String {
        return v == null ? "" : v.toString();
    }
}

class CommListener extends Communications.ConnectionListener {
    private var _session as WatchSession;

    function initialize(session as WatchSession) {
        ConnectionListener.initialize();
        _session = session;
    }

    function onComplete() as Void {}

    function onError() as Void {
        _session.onSendError();
    }
}
