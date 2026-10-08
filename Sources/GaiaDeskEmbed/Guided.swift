// Guided input on iOS, delivered inside the app through public UIKit API only.
// iOS has no public way to synthesise a touch, so this is PARTIAL, and says
// so (the console is told `input: partial`):
//
//   click   a UIControl under the point gets its action (button: touchUpInside;
//           switch: toggled; segmented control: that segment; text field or
//           text view: it becomes first responder); a table or collection
//           cell is selected through its delegate. Anything else (SwiftUI,
//           custom gesture recognisers, web views) gets a "Tap here" ring for
//           the customer instead, answered `hint_shown`.
//   scroll  the scroll view under the point scrolls (clamped to its content).
//   type    text goes into the first responder (`UIKeyInput.insertText`).
//   key     Enter, Backspace, ArrowLeft/Right, Home/End, Escape on the first
//           responder; others are `unsupported`.
//   pointer the agent's pointer is drawn; highlight draws a ring.
//
// The library has already checked view-only/pause/rate and that a point is
// inside the window and not masked. Checked here, at the moment of delivery:
// the app is active (`not_focused`) and the point is not the indicator
// (`embed_ui`).

import UIKit

enum Guided {
    /// Deliver one request; nil when applied, else why not. `masks`: what is
    /// masked now (window points).
    @MainActor
    static func deliver(_ json: String, indicator: Indicator?, masks: [CGRect]) -> String? {
        guard let d = json.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let t = o["t"] as? String else { return "unsupported" }
        guard UIApplication.shared.applicationState == .active, let window = Host.keyWindow(excluding: indicator?.window) else { return "not_focused" }
        let point = CGPoint(x: o["x"] as? Double ?? 0, y: o["y"] as? Double ?? 0)
        let p = window.convert(point, from: nil as UIView?)
        switch t {
        case "pointer":
            indicator?.showPointer(at: point)
            return nil
        case "highlight":
            indicator?.showRing(at: point, text: nil)
            return nil
        case "click":
            if indicator?.onPill(point) == true { return "embed_ui" }
            if activate(at: p, in: window) { return nil }
            indicator?.showRing(at: point, text: "Tap here")
            return "hint_shown"
        case "scroll":
            if indicator?.onPill(point) == true { return "embed_ui" }
            return scroll(at: p, in: window, dx: o["dx"] as? Double ?? 0, dy: o["dy"] as? Double ?? 0) ? nil : "nothing_there"
        case "type":
            if let r = firstResponder(), let why = refusesTyping(r, masks: masks) { return why }
            guard let text = o["text"] as? String, let input = firstResponder() as? UIKeyInput else { return "not_editable" }
            input.insertText(text)
            return nil
        case "key":
            if let r = firstResponder(), let why = refusesTyping(r, masks: masks) { return why }
            return key(o["key"] as? String ?? "")
        default:
            return "unsupported"
        }
    }

    /// Typing into a password field, or into anything masked, is refused
    /// (`masked`): the agent cannot see it, so it cannot be theirs to edit.
    @MainActor
    static func refusesTyping(_ r: UIResponder, masks: [CGRect]) -> String? {
        if let t = r as? UITextInputTraits, t.isSecureTextEntry == true { return "masked" }
        if let v = r as? UIView, v.window != nil {
            let rect = v.convert(v.bounds, to: nil)
            if masks.contains(where: { $0.intersects(rect) }) { return "masked" }
        }
        return nil
    }

    /// The control or cell under `p`, activated through its public API.
    static func activate(at p: CGPoint, in window: UIWindow) -> Bool {
        var v = window.hitTest(p, with: nil)
        while let view = v {
            if let c = view as? UIControl, c.isEnabled {
                return activate(control: c, at: window.convert(p, to: c))
            }
            if let cell = view as? UITableViewCell, let table = enclosing(UITableView.self, of: cell), let ip = table.indexPath(for: cell) {
                if let d = table.delegate, d.responds(to: #selector(UITableViewDelegate.tableView(_:willSelectRowAt:))), d.tableView?(table, willSelectRowAt: ip) == nil {
                    return false // the app refuses that row
                }
                table.selectRow(at: ip, animated: true, scrollPosition: .none)
                table.delegate?.tableView?(table, didSelectRowAt: ip)
                return true
            }
            if let cell = view as? UICollectionViewCell, let cv = enclosing(UICollectionView.self, of: cell), let ip = cv.indexPath(for: cell) {
                cv.selectItem(at: ip, animated: true, scrollPosition: [])
                cv.delegate?.collectionView?(cv, didSelectItemAt: ip)
                return true
            }
            v = view.superview
        }
        return false
    }

    static func activate(control c: UIControl, at p: CGPoint) -> Bool {
        switch c {
        case let s as UISwitch:
            s.setOn(!s.isOn, animated: true)
            s.sendActions(for: .valueChanged)
        case let seg as UISegmentedControl where seg.numberOfSegments > 0:
            let i = min(seg.numberOfSegments - 1, max(0, Int(p.x / max(1, seg.bounds.width) * CGFloat(seg.numberOfSegments))))
            seg.selectedSegmentIndex = i
            seg.sendActions(for: .valueChanged)
        case let f as UITextField:
            _ = f.becomeFirstResponder()
        default:
            c.sendActions(for: .touchUpInside)
            c.sendActions(for: .primaryActionTriggered)
        }
        return true
    }

    static func scroll(at p: CGPoint, in window: UIWindow, dx: Double, dy: Double) -> Bool {
        guard let hit = window.hitTest(p, with: nil) else { return false }
        var v: UIView? = hit
        while let view = v {
            if let s = view as? UIScrollView, s.isScrollEnabled {
                let maxX = max(-s.adjustedContentInset.left, s.contentSize.width - s.bounds.width + s.adjustedContentInset.right)
                let maxY = max(-s.adjustedContentInset.top, s.contentSize.height - s.bounds.height + s.adjustedContentInset.bottom)
                let x = min(maxX, max(-s.adjustedContentInset.left, s.contentOffset.x + dx))
                let y = min(maxY, max(-s.adjustedContentInset.top, s.contentOffset.y + dy))
                s.setContentOffset(CGPoint(x: x, y: y), animated: true)
                return true
            }
            v = view.superview
        }
        return false
    }

    static func key(_ k: String) -> String? {
        guard let r = firstResponder() else { return "not_editable" }
        switch k {
        case "Escape":
            r.resignFirstResponder()
            return nil
        case "Enter":
            if let f = r as? UITextField {
                if f.delegate?.textFieldShouldReturn?(f) == false { return nil }
                f.sendActions(for: .editingDidEndOnExit)
                return nil
            }
            guard let input = r as? UIKeyInput else { return "not_editable" }
            input.insertText("\n")
            return nil
        case "Backspace":
            guard let input = r as? UIKeyInput else { return "not_editable" }
            input.deleteBackward()
            return nil
        case "ArrowLeft", "ArrowRight", "Home", "End":
            guard let t = r as? UITextInput, let sel = t.selectedTextRange else { return "not_editable" }
            let target: UITextPosition?
            switch k {
            case "ArrowLeft": target = t.position(from: sel.start, offset: -1)
            case "ArrowRight": target = t.position(from: sel.end, offset: 1)
            case "Home": target = t.beginningOfDocument
            default: target = t.endOfDocument
            }
            if let target { t.selectedTextRange = t.textRange(from: target, to: target) }
            return nil
        default:
            return "unsupported"
        }
    }

    static func enclosing<T: UIView>(_: T.Type, of v: UIView) -> T? {
        var s = v.superview
        while let x = s {
            if let t = x as? T { return t }
            s = x.superview
        }
        return nil
    }

    /// The first responder, found the public way (an action sent to nil
    /// reaches it).
    static func firstResponder() -> UIResponder? {
        FirstResponder.found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.gd_embed_reportFirstResponder(_:)), to: nil, from: nil, for: nil)
        return FirstResponder.found
    }
}

enum FirstResponder {
    static weak var found: UIResponder?
}

extension UIResponder {
    @objc func gd_embed_reportFirstResponder(_ sender: Any?) {
        FirstResponder.found = self
    }
}
