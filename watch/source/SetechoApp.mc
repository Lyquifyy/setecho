import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

// Setecho on the watch (HANDOFF.md §7, Garmin watch): wrist sets and reps, haptics, and messages
// to the phone. No network, no models. The phone owns the plan and the log; the watch reports.
class SetechoApp extends Application.AppBase {
    private var _session as WatchSession?;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Dictionary?) as Void {
        _session = new WatchSession();
        (_session as WatchSession).start();
    }

    function onStop(state as Dictionary?) as Void {
        if (_session != null) {
            (_session as WatchSession).stop();
        }
    }

    function getInitialView() as [Views] or [Views, InputDelegates] {
        var session = _session as WatchSession;
        var view = new SetechoView(session);
        session.setView(view);
        return [view, new SetechoDelegate(session)];
    }
}
