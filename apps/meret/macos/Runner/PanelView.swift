import Cocoa

/// The instrument's colours (`theme/tokens.dart`), for the one native panel.
enum Tok {
  static let panel = NSColor(srgbRed: 0x0A / 255, green: 0x10 / 255, blue: 0x24 / 255, alpha: 1)
  static let line = NSColor(srgbRed: 0x18 / 255, green: 0x20 / 255, blue: 0x3C / 255, alpha: 1)
  static let rule = NSColor(srgbRed: 0x26 / 255, green: 0x30 / 255, blue: 0x56 / 255, alpha: 1)
  static let ink = NSColor(srgbRed: 0xEB / 255, green: 0xE6 / 255, blue: 0xDA / 255, alpha: 1)
  static let muted = NSColor(srgbRed: 0xA6 / 255, green: 0xAA / 255, blue: 0xC0 / 255, alpha: 1)
  static let faint = NSColor(srgbRed: 0x6A / 255, green: 0x71 / 255, blue: 0x94 / 255, alpha: 1)
  static let dim = NSColor(srgbRed: 0x47 / 255, green: 0x4E / 255, blue: 0x70 / 255, alpha: 1)
  static let gold = NSColor(srgbRed: 0xD2 / 255, green: 0xA6 / 255, blue: 0x4E / 255, alpha: 1)
  static let sky = NSColor(srgbRed: 0x07 / 255, green: 0x0B / 255, blue: 0x1A / 255, alpha: 1)
  static let ok = NSColor(srgbRed: 0x8F / 255, green: 0xC2 / 255, blue: 0xA2 / 255, alpha: 1)
  static let warn = NSColor(srgbRed: 0xE3 / 255, green: 0xA0 / 255, blue: 0x66 / 255, alpha: 1)

  static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
  static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .monospacedSystemFont(ofSize: size, weight: weight) }
}

/// Plate 10's drop-down: cover, title, the bar, the controls, the verdict,
/// three pick-up rows and two buttons. Dumb on purpose: every string comes
/// worded from Dart, and every click goes back as a command.
final class PanelViewController: NSViewController {
  var onCommand: ((String, Any?) -> Void)?
  var onClose: (() -> Void)?

  private let cover = NSImageView()
  private let heading = Label(Tok.sans(14, .semibold), Tok.ink)
  private let subtitle = Label(Tok.sans(12.5), Tok.muted)
  private let why = Label(Tok.mono(11), Tok.gold)
  private let bar = BarView()
  private let previous = IconButton("backward.fill")
  private let play = IconButton("play.fill")
  private let next = IconButton("forward.fill")
  private let time = Label(Tok.mono(11.5), Tok.faint)
  private let mode = Chip("This Mac")
  private let verdict = Label(Tok.mono(12, .medium), Tok.ok)
  private let pickUpHeader = SectionLabel("Pick up", hint: "")
  private let pickUp = NSStackView()
  private var now = NowOutside()

  override func loadView() {
    let root = PanelRoot()
    root.orientation = .vertical
    root.alignment = .leading
    root.spacing = 12
    root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 12, right: 14)
    root.wantsLayer = true
    root.layer?.backgroundColor = Tok.panel.cgColor
    root.frame = NSRect(x: 0, y: 0, width: 360, height: 100)
    view = root

    cover.wantsLayer = true
    cover.layer?.cornerRadius = 4
    cover.layer?.masksToBounds = true
    cover.layer?.borderWidth = 1
    cover.layer?.borderColor = Tok.rule.cgColor
    cover.imageScaling = .scaleProportionallyUpOrDown
    cover.widthAnchor.constraint(equalToConstant: 56).isActive = true
    cover.heightAnchor.constraint(equalToConstant: 56).isActive = true

    let text = NSStackView(views: [heading, subtitle, why])
    text.orientation = .vertical
    text.alignment = .leading
    text.spacing = 2
    let head = NSStackView(views: [cover, text])
    head.orientation = .horizontal
    head.alignment = .centerY
    head.spacing = 12
    root.addArrangedSubview(head)
    head.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28).isActive = true

    bar.onSeek = { [weak self] fraction in
      guard let self, let length = self.now.lengthMs else { return }
      self.onCommand?("seek", fraction * length)
    }
    root.addArrangedSubview(bar)
    bar.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28).isActive = true
    bar.heightAnchor.constraint(equalToConstant: 3).isActive = true

    play.wantsLayer = true
    play.layer?.cornerRadius = 16
    play.layer?.backgroundColor = Tok.gold.cgColor
    play.contentTintColor = Tok.sky
    play.widthAnchor.constraint(equalToConstant: 32).isActive = true
    play.heightAnchor.constraint(equalToConstant: 32).isActive = true
    previous.target = self; previous.action = #selector(previousClicked)
    play.target = self; play.action = #selector(playClicked)
    next.target = self; next.action = #selector(nextClicked)
    let controls = NSStackView(views: [previous, play, next, time, NSView(), mode])
    controls.orientation = .horizontal
    controls.alignment = .centerY
    controls.spacing = 16
    root.addArrangedSubview(controls)
    controls.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28).isActive = true

    root.addArrangedSubview(verdict)
    root.addArrangedSubview(pickUpHeader)
    pickUpHeader.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28).isActive = true
    pickUp.orientation = .vertical
    pickUp.alignment = .leading
    pickUp.spacing = 0
    root.addArrangedSubview(pickUp)
    pickUp.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -28).isActive = true
    root.setCustomSpacing(0, after: pickUpHeader)
  }

  /// A new Now: everything but the pick-up rows, which arrive separately.
  func show(_ n: NowOutside) {
    now = n
    if n.loaded {
      heading.stringValue = n.title
      subtitle.stringValue = n.subtitle
      cover.image = n.cover.flatMap { NSImage(contentsOfFile: $0) }
      cover.layer?.backgroundColor = Tok.line.cgColor
    } else {
      heading.stringValue = "Nothing playing"
      subtitle.stringValue = ""
      cover.image = nil
    }
    why.stringValue = n.why ?? ""
    why.isHidden = n.why == nil
    play.image = NSImage(systemSymbolName: n.playing ? "pause.fill" : "play.fill", accessibilityDescription: n.playing ? "Pause" : "Play")
    previous.isEnabled = n.loaded
    next.isEnabled = n.loaded
    bar.isHidden = !n.loaded
    time.isHidden = !n.loaded
    if let error = n.error {
      verdict.stringValue = error
      verdict.textColor = Tok.warn
      verdict.isHidden = false
    } else if let v = n.verdict {
      verdict.stringValue = v
      verdict.textColor = n.warn ? Tok.warn : Tok.ok
      verdict.isHidden = false
    } else {
      verdict.isHidden = true
    }
    tick(n)
    resize()
  }

  /// Once a second while playing: the bar and the time.
  func tick(_ n: NowOutside) {
    now = n
    let position = n.positionMs
    bar.fraction = n.lengthMs.map { $0 > 0 ? position / $0 : 0 } ?? 0
    let text = NSMutableAttributedString(string: Outside.clock(position), attributes: [.foregroundColor: Tok.ink, .font: Tok.mono(11.5)])
    if let length = n.lengthMs {
      text.append(NSAttributedString(string: " / \(Outside.clock(length))", attributes: [.foregroundColor: Tok.faint, .font: Tok.mono(11.5)]))
    }
    time.attributedStringValue = text
  }

  func showPickUp(_ rows: [[String: Any]]) {
    pickUp.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for row in rows {
      guard let id = row["releaseId"] as? NSNumber else { continue }
      let r = PickUpRow(title: row["title"] as? String ?? "", detail: row["detail"] as? String ?? "", cover: row["cover"] as? String)
      r.onClick = { [weak self] in
        self?.onCommand?("pickUp", id.int64Value)
        self?.onClose?()
      }
      pickUp.addArrangedSubview(r)
      r.widthAnchor.constraint(equalTo: pickUp.widthAnchor).isActive = true
    }
    let empty = rows.isEmpty
    pickUpHeader.isHidden = empty
    pickUp.isHidden = empty
    resize()
  }

  /// A menu item's view is as big as its frame; autolayout fills it.
  private func resize() {
    view.layoutSubtreeIfNeeded()
    view.frame = NSRect(x: 0, y: 0, width: 360, height: view.fittingSize.height)
  }

  @objc private func previousClicked() { onCommand?("previous", nil) }
  @objc private func playClicked() { onCommand?("toggle", nil) }
  @objc private func nextClicked() { onCommand?("next", nil) }
}

/// The panel's root. NSMenu pads view items above and below with its own
/// vibrant background; the first time the root lands in the menu window
/// it slides a panel-coloured view under everything so the bands match.
final class PanelRoot: NSStackView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let content = window?.contentView, !(content.subviews.first is Backdrop) else { return }
    let backdrop = Backdrop(frame: content.bounds)
    backdrop.autoresizingMask = [.width, .height]
    backdrop.wantsLayer = true
    backdrop.layer?.backgroundColor = Tok.panel.cgColor
    content.addSubview(backdrop, positioned: .below, relativeTo: nil)
  }
  final class Backdrop: NSView {}
}

/// The panel's two commands, reachable by button and by key.
enum PanelKey { case open, playSomething }

/// The panel's bottom row, its own view-backed menu item so the panel
/// view above it keeps its own padding.
final class ActionsRow: NSView {
  init(onKey: @escaping (PanelKey) -> Void) {
    self.onKey = onKey
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = Tok.panel.cgColor
    let something = TextButton("Play something", key: "⇧Space")
    something.target = self; something.action = #selector(somethingClicked)
    let openMeret = TextButton("Open Meret", key: "⌘O")
    openMeret.target = self; openMeret.action = #selector(openClicked)
    let buttons = NSStackView(views: [something, openMeret])
    buttons.orientation = .horizontal
    buttons.spacing = 8
    something.setContentHuggingPriority(.defaultLow, for: .horizontal)
    buttons.translatesAutoresizingMaskIntoConstraints = false
    addSubview(buttons)
    NSLayoutConstraint.activate([
      buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      buttons.topAnchor.constraint(equalTo: topAnchor),
      buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
    ])
    frame = NSRect(x: 0, y: 0, width: 360, height: 44)
  }
  required init?(coder: NSCoder) { fatalError() }
  private let onKey: (PanelKey) -> Void
  @objc private func somethingClicked() { onKey(.playSomething) }
  @objc private func openClicked() { onKey(.open) }
}

// MARK: Pieces

final class Label: NSTextField {
  init(_ font: NSFont, _ color: NSColor) {
    super.init(frame: .zero)
    isEditable = false
    isBordered = false
    isSelectable = false
    drawsBackground = false
    self.font = font
    textColor = color
    lineBreakMode = .byTruncatingTail
    maximumNumberOfLines = 1
    cell?.truncatesLastVisibleLine = true
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }
  required init?(coder: NSCoder) { fatalError() }
}

/// A caps label with a rule beneath and a hint at the right (`.lbl`).
final class SectionLabel: NSView {
  init(_ text: String, hint: String) {
    super.init(frame: .zero)
    let left = Label(Tok.mono(10.5, .medium), Tok.faint)
    left.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [.kern: 0.7, .font: Tok.mono(10.5, .medium), .foregroundColor: Tok.faint])
    let right = Label(Tok.mono(10.5), Tok.dim)
    right.stringValue = hint
    right.alignment = .right
    let rule = NSView()
    rule.wantsLayer = true
    rule.layer?.backgroundColor = Tok.rule.cgColor
    for v in [left, right, rule] {
      v.translatesAutoresizingMaskIntoConstraints = false
      addSubview(v)
    }
    NSLayoutConstraint.activate([
      left.leadingAnchor.constraint(equalTo: leadingAnchor),
      left.topAnchor.constraint(equalTo: topAnchor),
      right.trailingAnchor.constraint(equalTo: trailingAnchor),
      right.firstBaselineAnchor.constraint(equalTo: left.firstBaselineAnchor),
      right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 10),
      rule.leadingAnchor.constraint(equalTo: leadingAnchor),
      rule.trailingAnchor.constraint(equalTo: trailingAnchor),
      rule.topAnchor.constraint(equalTo: left.bottomAnchor, constant: 6),
      rule.heightAnchor.constraint(equalToConstant: 1),
      rule.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }
}

/// The progress line: a rule with the played part in gold; a click seeks.
final class BarView: NSView {
  var fraction: Double = 0 { didSet { needsDisplay = true } }
  var onSeek: ((Double) -> Void)?

  override func draw(_ dirtyRect: NSRect) {
    Tok.rule.setFill()
    bounds.fill()
    Tok.gold.setFill()
    NSRect(x: 0, y: 0, width: bounds.width * min(max(fraction, 0), 1), height: bounds.height).fill()
  }

  override func mouseDown(with event: NSEvent) {
    let x = convert(event.locationInWindow, from: nil).x
    guard bounds.width > 0 else { return }
    onSeek?(Double(min(max(x / bounds.width, 0), 1)))
  }

  // A 3-point line is hard to hit; take the 12 points around it.
  override func hitTest(_ point: NSPoint) -> NSView? {
    let reach = bounds.insetBy(dx: 0, dy: -6)
    return reach.contains(convert(point, from: superview)) ? self : nil
  }
}

final class IconButton: NSButton {
  init(_ symbol: String) {
    super.init(frame: .zero)
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    imagePosition = .imageOnly
    isBordered = false
    bezelStyle = .regularSquare
    contentTintColor = Tok.muted
    symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    setButtonType(.momentaryChange)
    refusesFirstResponder = true
  }
  required init?(coder: NSCoder) { fatalError() }
}

/// `.btn`: a bordered text button with a muted key hint.
final class TextButton: NSButton {
  init(_ text: String, key: String) {
    super.init(frame: .zero)
    isBordered = false
    wantsLayer = true
    layer?.borderWidth = 1
    layer?.borderColor = Tok.rule.cgColor
    let t = NSMutableAttributedString(string: text, attributes: [.font: Tok.sans(12.5, .medium), .foregroundColor: Tok.ink])
    t.append(NSAttributedString(string: "  \(key)", attributes: [.font: Tok.mono(11), .foregroundColor: Tok.faint]))
    attributedTitle = t
    setButtonType(.momentaryChange)
    refusesFirstResponder = true
    heightAnchor.constraint(equalToConstant: 30).isActive = true
  }
  required init?(coder: NSCoder) { fatalError() }
  override var intrinsicContentSize: NSSize {
    var s = super.intrinsicContentSize
    s.width += 22
    return s
  }
}

final class Chip: NSView {
  init(_ text: String) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.borderWidth = 1
    layer?.borderColor = Tok.rule.cgColor
    let label = Label(Tok.mono(11), Tok.muted)
    label.stringValue = text
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
      label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }
}

/// One pick-up row: the cover, the release, and where it resumes.
final class PickUpRow: NSView {
  var onClick: (() -> Void)?

  init(title: String, detail: String, cover: String?) {
    super.init(frame: .zero)
    let art = NSImageView()
    art.wantsLayer = true
    art.layer?.cornerRadius = 2
    art.layer?.masksToBounds = true
    art.layer?.backgroundColor = Tok.line.cgColor
    art.imageScaling = .scaleProportionallyUpOrDown
    art.image = cover.flatMap { NSImage(contentsOfFile: $0) }
    let t = Label(Tok.sans(13), Tok.ink)
    t.stringValue = title
    let x = Label(Tok.mono(11.5), Tok.faint)
    x.stringValue = detail
    x.alignment = .right
    x.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    x.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    let rule = NSView()
    rule.wantsLayer = true
    rule.layer?.backgroundColor = Tok.line.cgColor
    for v in [art, t, x, rule] {
      v.translatesAutoresizingMaskIntoConstraints = false
      addSubview(v)
    }
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 34),
      art.leadingAnchor.constraint(equalTo: leadingAnchor),
      art.centerYAnchor.constraint(equalTo: centerYAnchor),
      art.widthAnchor.constraint(equalToConstant: 22),
      art.heightAnchor.constraint(equalToConstant: 22),
      t.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 10),
      t.centerYAnchor.constraint(equalTo: centerYAnchor),
      x.leadingAnchor.constraint(greaterThanOrEqualTo: t.trailingAnchor, constant: 10),
      x.trailingAnchor.constraint(equalTo: trailingAnchor),
      x.centerYAnchor.constraint(equalTo: centerYAnchor),
      x.widthAnchor.constraint(lessThanOrEqualToConstant: 150),
      rule.leadingAnchor.constraint(equalTo: leadingAnchor),
      rule.trailingAnchor.constraint(equalTo: trailingAnchor),
      rule.bottomAnchor.constraint(equalTo: bottomAnchor),
      rule.heightAnchor.constraint(equalToConstant: 1),
    ])
    addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
  }
  required init?(coder: NSCoder) { fatalError() }

  @objc private func clicked() { onClick?() }
}
