// Page shortcuts must yield to browser shortcuts, IME input, and controls.
export function ignorePageShortcut(event: KeyboardEvent) {
  return (
    event.defaultPrevented ||
    event.isComposing ||
    event.repeat ||
    event.metaKey ||
    event.ctrlKey ||
    event.altKey ||
    event.shiftKey ||
    (event.target instanceof Element &&
      Boolean(
        event.target.closest(
          'input, textarea, select, button, a, [contenteditable]:not([contenteditable="false"]), [role="button"], [role="combobox"], [role="textbox"], [role="menu"], [role="listbox"], [role="dialog"]',
        ),
      ))
  )
}
