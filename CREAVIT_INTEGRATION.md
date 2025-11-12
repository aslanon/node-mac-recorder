# Creavit Desktop Multi-Window Recording Integration Plan

## 🎯 Hedef

Creavit Desktop'a aynı anda iki pencere kaydı özelliğini eklemek:
1. Kullanıcı ilk pencereyi seçer (overlay ile)
2. İkinci pencereyi seçer (overlay ile)
3. "Kayıt Başlat" butonuna basınca her iki pencere de kaydedilir
4. Kayıt durdurulunca CRVT dosyası oluşturulur
5. Editor'da iki clip yan yana (multi-row layout) gösterilir

## 📋 Mimari Plan

### 1. UI/UX Flow

```
┌─────────────────────────────────────────────────────────────┐
│  Kayıt Başlatma Penceresi                                  │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  [📹 Pencere Seç]  [📹 İkinci Pencere Ekle] ← YENİ BUTON │
│                                                             │
│  ┌───────────────────┐  ┌───────────────────┐             │
│  │ Window 1          │  │ Window 2          │             │
│  │ ┌───────────┐     │  │ ┌───────────┐     │             │
│  │ │ [Preview] │     │  │ │ [Preview] │     │             │
│  │ └───────────┘     │  │ └───────────┘     │             │
│  │ Chrome           │  │ Finder            │             │
│  │ [Değiştir] [✕]  │  │ [Değiştir] [✕]   │             │
│  └───────────────────┘  └───────────────────┘             │
│                                                             │
│            [🔴 Kayıt Başlat]                               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 2. Dosya Yapısı

```
creavit.studio/desktop/
├── src/
│   ├── main/
│   │   ├── recording/
│   │   │   ├── MultiWindowRecorder.js       ← YENİ
│   │   │   ├── RecorderManager.js            (mevcut - güncelle)
│   │   │   └── WindowSelector.js             ← YENİ
│   │   └── ...
│   ├── renderer/
│   │   ├── components/
│   │   │   ├── recording/
│   │   │   │   ├── MultiWindowSelector.tsx  ← YENİ
│   │   │   │   ├── WindowPreview.tsx        ← YENİ
│   │   │   │   └── RecordingControls.tsx    (güncelle)
│   │   │   └── editor/
│   │   │       ├── timeline/
│   │   │       │   ├── MultiRowTimeline.tsx  ← YENİ
│   │   │       │   └── ClipSegment.tsx       (güncelle)
│   │   │       └── ...
│   │   └── ...
│   └── shared/
│       ├── types/
│       │   └── crvt.ts                        (güncelle)
│       └── ...
└── ...
```

## 🔧 Implementation Details

### Phase 1: Multi-Window Recorder Manager

**Dosya:** `src/main/recording/MultiWindowRecorder.js`

```javascript
const MacRecorder = require('node-mac-recorder/index-multiprocess');

class MultiWindowRecorder {
  constructor() {
    this.recorders = [];
    this.windows = [];
    this.isRecording = false;
    this.outputFiles = [];
  }

  async addWindow(windowId) {
    const recorder = new MacRecorder();

    this.recorders.push({
      recorder,
      windowId,
      outputPath: null,
      preview: await this.getWindowPreview(windowId)
    });

    return this.recorders.length - 1; // index
  }

  removeWindow(index) {
    const recorderInfo = this.recorders[index];
    if (recorderInfo && recorderInfo.recorder) {
      recorderInfo.recorder.destroy();
    }
    this.recorders.splice(index, 1);
  }

  async startRecording(outputDir) {
    if (this.isRecording) return;

    const timestamp = Date.now();
    this.outputFiles = [];

    // Start all recorders sequentially
    for (let i = 0; i < this.recorders.length; i++) {
      const recInfo = this.recorders[i];
      const outputPath = path.join(outputDir, `window_${i}_${timestamp}.mov`);

      await recInfo.recorder.startRecording(outputPath, {
        windowId: recInfo.windowId,
        frameRate: 30,
        captureCursor: true,
        preferScreenCaptureKit: true
      });

      this.outputFiles.push(outputPath);

      // Wait for ScreenCaptureKit init
      if (i < this.recorders.length - 1) {
        await new Promise(r => setTimeout(r, 1000));
      }
    }

    this.isRecording = true;
  }

  async stopRecording() {
    if (!this.isRecording) return;

    // Stop all recorders in parallel
    await Promise.all(
      this.recorders.map(recInfo => recInfo.recorder.stopRecording())
    );

    this.isRecording = false;

    return this.outputFiles;
  }

  destroy() {
    this.recorders.forEach(recInfo => {
      recInfo.recorder.destroy();
    });
    this.recorders = [];
    this.outputFiles = [];
  }
}

module.exports = MultiWindowRecorder;
```

### Phase 2: Window Selection UI

**Komponente:** `MultiWindowSelector.tsx`

```typescript
interface WindowInfo {
  id: number;
  appName: string;
  title: string;
  preview?: string;
}

interface MultiWindowSelectorProps {
  onWindowsSelected: (windows: WindowInfo[]) => void;
}

export const MultiWindowSelector: React.FC<MultiWindowSelectorProps> = ({
  onWindowsSelected
}) => {
  const [selectedWindows, setSelectedWindows] = useState<WindowInfo[]>([]);
  const [isSelecting, setIsSelecting] = useState(false);
  const [selectingIndex, setSelectingIndex] = useState<number | null>(null);

  const handleAddWindow = async (index: number) => {
    setIsSelecting(true);
    setSelectingIndex(index);

    // Show overlay window selector
    const selectedWindow = await window.electron.showWindowSelector();

    if (selectedWindow) {
      const newWindows = [...selectedWindows];
      newWindows[index] = selectedWindow;
      setSelectedWindows(newWindows);
      onWindowsSelected(newWindows);
    }

    setIsSelecting(false);
    setSelectingIndex(null);
  };

  const handleRemoveWindow = (index: number) => {
    const newWindows = selectedWindows.filter((_, i) => i !== index);
    setSelectedWindows(newWindows);
    onWindowsSelected(newWindows);
  };

  return (
    <div className="multi-window-selector">
      <div className="windows-grid">
        {/* Window 1 */}
        <WindowPreview
          window={selectedWindows[0]}
          onSelect={() => handleAddWindow(0)}
          onRemove={() => handleRemoveWindow(0)}
          label="Pencere 1"
          isSelecting={isSelecting && selectingIndex === 0}
        />

        {/* Add Second Window Button */}
        {selectedWindows[0] && !selectedWindows[1] && (
          <button
            className="add-window-btn"
            onClick={() => handleAddWindow(1)}
          >
            <PlusIcon />
            İkinci Pencere Ekle
          </button>
        )}

        {/* Window 2 */}
        {selectedWindows[1] && (
          <WindowPreview
            window={selectedWindows[1]}
            onSelect={() => handleAddWindow(1)}
            onRemove={() => handleRemoveWindow(1)}
            label="Pencere 2"
            isSelecting={isSelecting && selectingIndex === 1}
          />
        )}
      </div>

      <div className="window-count">
        {selectedWindows.length} pencere seçildi
      </div>
    </div>
  );
};
```

### Phase 3: CRVT Format Extension

**Tip Tanımı:** `crvt.ts`

```typescript
// Mevcut CRVT formatına eklenecek
interface CRVTClipSegment {
  id: string;
  type: 'screen' | 'camera' | 'audio' | 'cursor';
  filePath: string;
  startTime: number;
  endTime: number;
  duration: number;
  // YENİ: Multi-window için
  windowIndex?: number;      // Hangi pencere (0, 1, 2, ...)
  layoutRow?: number;         // Timeline'da hangi satırda
}

interface CRVTRecording {
  version: string;
  timestamp: number;
  duration: number;
  segments: CRVTClipSegment[];
  // YENİ: Multi-window metadata
  multiWindow?: {
    enabled: boolean;
    windowCount: number;
    windows: Array<{
      index: number;
      appName: string;
      title: string;
      filePath: string;
    }>;
  };
}
```

**CRVT Oluşturma:**

```javascript
// Multi-window recording bittiğinde
async function createMultiWindowCRVT(outputFiles, metadata) {
  const crvt = {
    version: '2.0',
    timestamp: Date.now(),
    duration: calculateDuration(outputFiles[0]),
    segments: [],
    multiWindow: {
      enabled: true,
      windowCount: outputFiles.length,
      windows: []
    }
  };

  // Her window için segment oluştur
  outputFiles.forEach((filePath, index) => {
    // Screen segment
    crvt.segments.push({
      id: `screen_${index}_${Date.now()}`,
      type: 'screen',
      filePath: filePath,
      startTime: 0,
      endTime: crvt.duration,
      duration: crvt.duration,
      windowIndex: index,
      layoutRow: index  // Her pencere farklı satırda
    });

    // Cursor segment (varsa)
    const cursorFile = findCursorFile(filePath);
    if (cursorFile) {
      crvt.segments.push({
        id: `cursor_${index}_${Date.now()}`,
        type: 'cursor',
        filePath: cursorFile,
        startTime: 0,
        endTime: crvt.duration,
        duration: crvt.duration,
        windowIndex: index,
        layoutRow: index
      });
    }

    // Window metadata
    crvt.multiWindow.windows.push({
      index: index,
      appName: metadata[index].appName,
      title: metadata[index].title,
      filePath: filePath
    });
  });

  return crvt;
}
```

### Phase 4: Editor Multi-Row Timeline

**Komponente:** `MultiRowTimeline.tsx`

```typescript
export const MultiRowTimeline: React.FC<TimelineProps> = ({
  recording
}) => {
  // Group segments by layoutRow
  const segmentsByRow = useMemo(() => {
    const rows = new Map<number, CRVTClipSegment[]>();

    recording.segments.forEach(segment => {
      const row = segment.layoutRow ?? 0;
      if (!rows.has(row)) {
        rows.set(row, []);
      }
      rows.get(row)!.push(segment);
    });

    return rows;
  }, [recording]);

  return (
    <div className="multi-row-timeline">
      {Array.from(segmentsByRow.entries()).map(([rowIndex, segments]) => (
        <div
          key={rowIndex}
          className="timeline-row"
          data-window-index={rowIndex}
        >
          <div className="row-label">
            {recording.multiWindow?.windows[rowIndex]?.appName || `Window ${rowIndex + 1}`}
          </div>

          <div className="row-segments">
            {segments.map(segment => (
              <ClipSegment
                key={segment.id}
                segment={segment}
                duration={recording.duration}
                onSelect={() => handleSegmentSelect(segment)}
              />
            ))}
          </div>
        </div>
      ))}
    </div>
  );
};
```

**CSS Styling:**

```css
.multi-row-timeline {
  display: flex;
  flex-direction: column;
  gap: 8px;
}

.timeline-row {
  display: flex;
  align-items: center;
  min-height: 60px;
  border: 1px solid #333;
  border-radius: 4px;
  background: #1a1a1a;
}

.row-label {
  width: 120px;
  padding: 0 12px;
  font-weight: 500;
  color: #fff;
  border-right: 1px solid #333;
}

.row-segments {
  flex: 1;
  display: flex;
  position: relative;
  padding: 8px;
}
```

## 🔄 Integration Flow

### 1. Kayıt Başlatma

```javascript
// RecordingWindow.tsx
const handleStartRecording = async () => {
  if (selectedWindows.length === 0) {
    showError('En az bir pencere seçin');
    return;
  }

  // Multi-window recorder oluştur
  const multiRecorder = new MultiWindowRecorder();

  // Windows ekle
  for (const window of selectedWindows) {
    await multiRecorder.addWindow(window.id);
  }

  // Kaydı başlat
  const outputDir = getOutputDirectory();
  await multiRecorder.startRecording(outputDir);

  setIsRecording(true);
  setRecorder(multiRecorder);
};
```

### 2. Kayıt Durdurma

```javascript
const handleStopRecording = async () => {
  if (!recorder) return;

  // Tüm kayıtları durdur
  const outputFiles = await recorder.stopRecording();

  // CRVT dosyası oluştur
  const crvt = await createMultiWindowCRVT(outputFiles, {
    windows: selectedWindows,
    timestamp: recordingStartTime
  });

  // CRVT dosyasını kaydet
  const crvtPath = await saveCRVT(crvt);

  // Recorder'ı temizle
  recorder.destroy();

  // Editor'ı aç
  openEditor(crvtPath);
};
```

### 3. Editor Loading

```javascript
// Editor.tsx
useEffect(() => {
  const loadRecording = async () => {
    const crvt = await loadCRVT(crvtPath);

    // Multi-window kontrolü
    if (crvt.multiWindow?.enabled) {
      setLayoutMode('multi-row');
      setWindowCount(crvt.multiWindow.windowCount);
    } else {
      setLayoutMode('single');
    }

    setRecording(crvt);
  };

  loadRecording();
}, [crvtPath]);
```

## ⚠️ Kritik Noktalar

### 1. Senkronizasyon

```javascript
// Her recorder'ın start timestamp'ini kaydet
const syncTimestamps = {
  window0: recorder0StartTime,
  window1: recorder1StartTime,
  offset: recorder1StartTime - recorder0StartTime  // ~1000ms
};

// Editor'da offset'i hesaba kat
segment.adjustedStartTime = segment.startTime - syncTimestamps.offset;
```

### 2. Dosya Adlandırma

```
output/
├── recording_1234567890/
│   ├── window_0_1234567890.mov      (Chrome)
│   ├── window_1_1234567891.mov      (Finder)
│   ├── temp_cursor_1234567890.json
│   ├── temp_cursor_1234567891.json
│   └── recording.crvt
```

### 3. Memory Management

```javascript
// Recorder'ları her zaman temizle
window.addEventListener('beforeunload', () => {
  if (multiRecorder) {
    multiRecorder.destroy();
  }
});
```

## 🧪 Test Senaryoları

1. ✅ İki pencere seçimi
2. ✅ Kayıt başlatma (sıralı)
3. ✅ Paralel kayıt
4. ✅ Kayıt durdurma
5. ✅ CRVT oluşturma
6. ✅ Editor'da yükleme
7. ✅ Multi-row timeline rendering
8. ✅ Segment senkronizasyonu

## 📦 Gerekli Paketler

```json
{
  "dependencies": {
    "node-mac-recorder": "latest"  // Multi-process support
  }
}
```

## 🎨 UI/UX İyileştirmeler

1. **Preview'lar**: Her seçilen pencere için küçük önizleme
2. **Drag & Drop**: Pencereleri sürükle bırak ile sırala
3. **Real-time Preview**: Kayıt sırasında her iki pencereyi göster
4. **Sync Indicator**: Hangi pencerenin kaydedildiğini göster
5. **Timeline Zoom**: Multi-row timeline için zoom kontrolü

## 🚀 Deployment

1. `node-mac-recorder` versiyonunu güncelle
2. Electron app'i rebuild et
3. Test kullanıcıları ile beta testi
4. Production'a release

## 📝 Notlar

- Her recorder kendi process'inde çalışır (izolasyon)
- ScreenCaptureKit init için 1 saniye bekleme şart
- CRVT formatı geriye uyumlu kalmalı
- Editor mevcut single-window kayıtları açabilmeli
- Performance: 2 pencere sorunsuz, 3-4 test edilmeli
