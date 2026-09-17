import AppKit

/// Some editors expose focus through the system or window tree, but return
/// AXError.noValue for the application's AXFocusedUIElement attribute.
enum DictationFocusResolver {
    nonisolated static func isTextInput(role: String?) -> Bool {
        guard let role else { return false }
        return ["AXTextField", "AXTextArea", "AXComboBox"].contains(role)
    }

    /// Never infer focus from a populated text field. A fallback must explicitly
    /// report focus and belong to the retained target process. In particular, the
    /// system-wide focus can be stale and refer to an entirely different app.
    nonisolated static func resolve<Element>(
        targetPID: pid_t,
        applicationFocus: () -> Element?,
        systemFocus: () -> Element?,
        focusedWindow: () -> Element?,
        processIdentifier: (Element) -> pid_t?,
        role: (Element) -> String?,
        isFocused: (Element) -> Bool,
        children: (Element) -> [Element],
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) -> Element? {
        let direct = applicationFocus()
        if let direct, processIdentifier(direct) == targetPID, isTextInput(role: role(direct)) {
            return direct
        }
        if let system = systemFocus(), processIdentifier(system) == targetPID,
           isTextInput(role: role(system)), isFocused(system) {
            return system
        }

        // A small breadth-first search finds nested native/web text controls
        // without scraping document text or walking an unbounded accessibility tree.
        let deadline = now() + 0.2
        var queue: [(element: Element, depth: Int)] = []
        if let window = focusedWindow() { queue.append((window, 0)) }
        var index = 0
        while index < queue.count, index < 128, now() < deadline {
            let (element, depth) = queue[index]
            index += 1
            guard processIdentifier(element) == targetPID else { continue }
            let isInput = isTextInput(role: role(element))
            if isInput, isFocused(element) { return element }
            // Do not walk inside editable fields, including password fields.
            guard depth < 12, !isInput else { continue }
            let remaining = 128 - queue.count
            if remaining > 0 {
                queue.append(contentsOf: children(element).prefix(remaining).map { ($0, depth + 1) })
            }
        }
        // Keep metadata for custom controls, but only text inputs may supply a
        // cursor snapshot (a web area can report a misleading empty 0,0 range).
        return direct.flatMap { processIdentifier($0) == targetPID ? $0 : nil }
    }
}
