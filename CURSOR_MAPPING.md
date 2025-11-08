# Cursor Type Mapping - Electron CSS ↔ macOS Native

Bu dosya, macOS native cursor type'larının Electron/CSS cursor constant'larına nasıl map edildiğini gösterir.

## ✅ Desteklenen Cursor Tipleri

### Temel Cursor'lar
| Electron Constant | CSS Value | macOS Native | Durum |
|-------------------|-----------|--------------|--------|
| `CURSOR_TYPES.default` | `default` | `NSCursor.arrowCursor` | ✅ |
| `CURSOR_TYPES.pointer` | `pointer` | `NSCursor.pointingHandCursor` | ✅ |
| `CURSOR_TYPES.text` | `text` | `NSCursor.IBeamCursor` | ✅ |
| `CURSOR_TYPES.grab` | `grab` | `NSCursor.openHandCursor` | ✅ |
| `CURSOR_TYPES.grabbing` | `grabbing` | `NSCursor.closedHandCursor` | ✅ |

### Action Cursor'lar
| Electron Constant | CSS Value | macOS Native | Durum |
|-------------------|-----------|--------------|--------|
| `CURSOR_TYPES.copy` | `copy` | `NSCursor.dragCopyCursor` | ✅ |
| `CURSOR_TYPES.alias` | `alias` | `NSCursor.dragLinkCursor` | ✅ |
| `CURSOR_TYPES["not-allowed"]` | `not-allowed` | `NSCursor.operationNotAllowedCursor` | ✅ |
| `CURSOR_TYPES.help` | `help` | Pattern: "help", "question" | ✅ |
| `CURSOR_TYPES.progress` | `progress` | Pattern: "progress", "wait", "busy" | ✅ |

### Zoom Cursor'lar
| Electron Constant | CSS Value | macOS Native | Durum |
|-------------------|-----------|--------------|--------|
| `CURSOR_TYPES.crosshair` | `crosshair` | `NSCursor.crosshairCursor` | ✅ |
| `CURSOR_TYPES["zoom-in"]` | `zoom-in` | Pattern: "zoom" + NOT "out" | ✅ |
| `CURSOR_TYPES["zoom-out"]` | `zoom-out` | Pattern: "zoom" + "out" | ✅ |

### Resize Cursor'lar
| Electron Constant | CSS Value | macOS Native | Durum |
|-------------------|-----------|--------------|--------|
| `CURSOR_TYPES["row-resize"]` | `row-resize` | `NSCursor.resizeUpDownCursor` | ✅ |
| `CURSOR_TYPES["col-resize"]` | `col-resize` | `NSCursor.resizeLeftRightCursor` | ✅ |
| `CURSOR_TYPES["ns-resize"]` | `ns-resize` | → maps to `row-resize` | ✅ |
| `CURSOR_TYPES["nwse-resize"]` | `nwse-resize` | Pattern: "diagonal-down", "nwse" | ✅ |
| `CURSOR_TYPES["nesw-resize"]` | `nesw-resize` | Pattern: "diagonal-up", "nesw" | ✅ |
| `CURSOR_TYPES["all-scroll"]` | `all-scroll` | Pattern: "all-scroll", "omnidirectional" | ✅ |

### Mouse Events
| Electron Constant | Event Type | Native Detection | Durum |
|-------------------|------------|------------------|--------|
| `MOUSE_EVENTS.MOVE` | `move` | CGEvent tracking | ✅ |
| `MOUSE_EVENTS.DOWN` | `mousedown` | Left button state | ✅ |
| `MOUSE_EVENTS.UP` | `mouseup` | Left button state | ✅ |
| `MOUSE_EVENTS.CLICK` | `click` | Click detection | ✅ |
| `MOUSE_EVENTS.DRAG` | `drag` | Mouse down + move | ✅ |
| `MOUSE_EVENTS.WHEEL` | `wheel` | Scroll wheel events | ✅ |
| `MOUSE_EVENTS.HOVER` | `hover` | Position stability | ✅ |

## 🔧 Detection Methods

### 1. Direct NSCursor Equality (En Güvenilir)
```objc
if (cursor == [NSCursor arrowCursor]) return @"default";
if (cursor == [NSCursor IBeamCursor]) return @"text";
```

### 2. Pattern Matching (Cursor Name/Description)
```objc
if ([normalized containsString:@"resize"]) { ... }
if ([normalized containsString:@"zoom"]) { ... }
```

### 3. Shape-Based Detection (Hotspot + Aspect Ratio)
```objc
// Text cursor: narrow (0.50), center hotspot (0.44, 0.50)
// Arrow cursor: medium (0.74), top-left hotspot (0.24, 0.17)
// Pointer cursor: square (1.00), left-center hotspot (0.41, 0.25)
```

### 4. Accessibility API (Context-Aware)
```objc
AXUIElementCopyElementAtPosition() → role → cursor type
```

## 📝 Notlar

### İyileştirmeler (Latest)
- ✅ `ns-resize` → `row-resize` mapping (Electron uyumluluğu)
- ✅ `all-scroll` pattern detection eklendi
- ✅ `progress` (wait/busy yerine)
- ✅ `contextualMenuCursor` → `pointer` mapping

### Bilinen Sınırlamalar
- Custom cursor'lar (resim-based) sadece pattern matching ile detect edilir
- Bazı uygulamalar custom cursor implementation kullanır (tam detection garanti edilemez)
- Shape-based detection sadece temel cursor'lar için optimize edilmiş

## 🧪 Test Etme

Cursor detection'ı test etmek için:

```javascript
const MacRecorder = require('./index.js');
const recorder = new MacRecorder();

// Start cursor tracking
await recorder.startCursorCapture('cursor-test.json', {
    videoRelative: false
});

// Move mouse over different UI elements
// Stop after a few seconds
await recorder.stopCursorCapture();

// Check cursor-test.json for detected cursor types
```

Her cursor event'inde `cursorType` field'ı Electron constant'larınızla uyumlu olacaktır.
