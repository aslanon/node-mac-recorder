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
| `CURSOR_TYPES.help` | `help` | HIServices `help` PNG/PDF | ✅ |
| `CURSOR_TYPES.progress` | `progress` | HIServices `busybutclickable` | ✅ |

### Zoom Cursor'lar
| Electron Constant | CSS Value | macOS Native | Durum |
|-------------------|-----------|--------------|--------|
| `CURSOR_TYPES.crosshair` | `crosshair` | `NSCursor.crosshairCursor` | ✅ |
| `CURSOR_TYPES["zoom-in"]` | `zoom-in` | `NSCursor.zoomInCursor` / HIServices `zoomin` | ✅ |
| `CURSOR_TYPES["zoom-out"]` | `zoom-out` | `NSCursor.zoomOutCursor` / HIServices `zoomout` | ✅ |

### Resize Cursor'lar
| Electron Constant | CSS Value | macOS Native | Durum |
|-------------------|-----------|--------------|--------|
| `CURSOR_TYPES["row-resize"]` | `row-resize` | `NSCursor.resizeUpDownCursor` | ✅ |
| `CURSOR_TYPES["col-resize"]` | `col-resize` | `NSCursor.resizeLeftRightCursor` | ✅ |
| `CURSOR_TYPES["ns-resize"]` | `ns-resize` | Dikey frame resize; `row-resize` ayrı tutulur | ✅ |
| `CURSOR_TYPES["nwse-resize"]` | `nwse-resize` | Frame resize: sol üst / sağ alt | ✅ |
| `CURSOR_TYPES["nesw-resize"]` | `nesw-resize` | Frame resize: sağ üst / sol alt | ✅ |
| `CURSOR_TYPES["all-scroll"]` | `all-scroll` | HIServices `move` | ✅ |

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

## Algılama sırası

1. `NSCursor.currentSystemCursor` ile ekranın gerçek imleci alınır. Kayıt işlemi arka plandayken uygulamanın kendi `currentCursor` değeri kullanılmaz.
2. Görselin piksel içeriği ve hotspot'u sistem imleçlerinin fingerprint'leriyle karşılaştırılır. AppKit görselleri ile HIServices PNG/PDF kaynaklarının 1x ve 2x temsilleri tanıtılır. Chromium/WebKit'in `move` gibi CoreCursor varyantları AppKit üzerinden, sistem gölgesi dahil render edilir; ham PDF aynı piksel görüntüsünü üretmez.
3. macOS 15 ve üzerinde frame resize'ın sekiz kenar/köşe konumu ve içe/dışa/iki yönlü çeşitleri; row/column resize'ın tek ve çift yönleri ayrı ayrı tanıtılır.
4. Görsel eşleşmezse bilinen imleç adları kullanılır. Tanınmayan görseller `default` olur; sadece boyutuna bakarak resize, zoom veya hand tipi atanmaz.
5. Sonuç desktop'taki SVG tiplerine normalize edilir. `context-menu` → `default`, `wait` → `progress`, `move` → `all-scroll`; tek yönlü resize tipleri ilgili eksene dönüştürülür.

`CGSCurrentCursorSeed` bir değişiklik sayacıdır; tip kimliği olarak kullanılmaz. Eski `MAC_RECORDER_CURSOR_MAP` dosyalarındaki `seed` alanları yok sayılır, fingerprint ve privateName eşleştirmeleri desteklenir. Accessibility tahminleri yalnızca debug çıktısındadır.

Konum değişmese bile cursor tipi değiştiğinde hareket/drag örneği kaydedilir.

## Test

macOS'ta, kurulu Node header'ları ve Xcode Command Line Tools ile:

```sh
npm run test:cursor
```

Test üretim kodunu derleyerek AppKit imleçlerini, bunların bağımsız 1x/2x bitmap kopyalarını, eski sistem kaynaklarını, isim eşleştirmelerini ve sabit konumdaki şekil değişikliklerini kontrol eder. AppKit sistem görsellerine erişim gerekir.

Gerçek WindowServer imlecini de doğrulamak için:

```sh
MAC_RECORDER_TEST_LIVE_CURSOR=1 npm run test:cursor
```

Bu seçenek imlecin altında kısa süreli bir test penceresi açar; test bitince pencere kapanır, önceki uygulama ve imleç geri yüklenir. Test sırasında fareyi hareket ettirmeyin.

Gerçek Chromium CSS imleçleri ve `grab → grabbing → grab` basma/bırakma geçişi için (önce `npm run build`):

```sh
MAC_RECORDER_ELECTRON=/path/to/Electron.app/Contents/MacOS/Electron npm run test:cursor:electron
```

Bu test de kısa süreli bir pencere açar. Electron zaten test ortamında kuruluysa executable değişkeni gerekmez.

Bilinmeyen özel uygulama görselleri veya gelecekte macOS'un sistem imleç görüntüsünü sağlamadığı durumlar `default` dönebilir. macOS 15 öncesindeki sistemler HIServices kaynakları ve mevcut NSCursor factory'leri üzerinden desteklenir.
