import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// The watch screens (DESIGN.md Watch): black, white text, cobalt for the logged ring, the target
// on a yellow fill with navy text, big numbers in the largest number font.
class SetechoView extends WatchUi.View {
    const COBALT = 0x2541D8;
    const YELLOW = 0xF0CD50;
    const NAVY = 0x171D36;
    const RED = 0xE5484D;

    private var _session as WatchSession;

    function initialize(session as WatchSession) {
        View.initialize();
        _session = session;
    }

    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var cy = h / 2;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var s = _session;
        if (s.state == :disconnected) {
            _text(dc, cx, cy - 30, Graphics.FONT_MEDIUM, "Open Setecho");
            _text(dc, cx, cy + 10, Graphics.FONT_MEDIUM, "on your phone.");
            if (s.lastError.length() > 0) {
                dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
                _text(dc, cx, h - 40, Graphics.FONT_XTINY, s.lastError);
            }
            return;
        }
        if (s.state == :inSet) {
            dc.setColor(RED, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(cx, cy - 60, 14);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            _text(dc, cx, cy - 10, Graphics.FONT_NUMBER_THAI_HOT, s.setElapsedSeconds().toString());
            _text(dc, cx, cy + 60, Graphics.FONT_SMALL, s.exercise);
            return;
        }
        if (s.state == :logged) {
            dc.setPenWidth(10);
            dc.setColor(COBALT, Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(cx, cy, cx - 8);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            _text(dc, cx, cy - 20, Graphics.FONT_NUMBER_HOT, s.loggedText);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            _text(dc, cx, cy + 40, Graphics.FONT_SMALL, s.loggedSource);
            return;
        }
        if (s.state == :rest) {
            var left = s.restRemainingSeconds();
            var mm = left / 60;
            var ss = left % 60;
            var clock = mm.toString() + ":" + (ss < 10 ? "0" : "") + ss.toString();
            _text(dc, cx, cy - 20, Graphics.FONT_NUMBER_THAI_HOT, clock);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            _text(dc, cx, cy + 50, Graphics.FONT_SMALL, "Next " + s.target);
            return;
        }
        // :target
        _text(dc, cx, cy - 95, Graphics.FONT_SMALL, s.exercise);
        var tagW = w - 60;
        dc.setColor(YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(cx - tagW / 2, cy - 45, tagW, 90, 16);
        dc.setColor(NAVY, Graphics.COLOR_TRANSPARENT);
        _text(dc, cx, cy, Graphics.FONT_NUMBER_HOT, s.target.length() > 0 ? s.target : "—");
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        _text(dc, cx, cy + 70, Graphics.FONT_SMALL, s.setLabel);
    }

    private function _text(dc as Dc, x as Number, y as Number, font as FontDefinition, text as String) as Void {
        dc.drawText(x, y, font, text, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}

// A tap anywhere is "done"; the back button is undo, confirmed on screen.
class SetechoDelegate extends WatchUi.BehaviorDelegate {
    private var _session as WatchSession;

    function initialize(session as WatchSession) {
        BehaviorDelegate.initialize();
        _session = session;
    }

    function onTap(evt as WatchUi.ClickEvent) as Boolean {
        _session.onTap();
        return true;
    }

    function onSelect() as Boolean {
        _session.onTap();
        return true;
    }

    function onBack() as Boolean {
        WatchUi.pushView(new WatchUi.Confirmation("Undo last set?"), new UndoConfirmDelegate(_session), WatchUi.SLIDE_UP);
        return true;
    }
}

class UndoConfirmDelegate extends WatchUi.ConfirmationDelegate {
    private var _session as WatchSession;

    function initialize(session as WatchSession) {
        ConfirmationDelegate.initialize();
        _session = session;
    }

    function onResponse(response as WatchUi.Confirm) as Boolean {
        if (response == WatchUi.CONFIRM_YES) {
            _session.onUndo();
        }
        return true;
    }
}
