# Creavit Desktop Integration - Code Snippets

## 📦 Kurulum

```bash
# creavit.studio/desktop dizininde
npm install --save /path/to/node-mac-recorder
```

## 🔧 Main Process (Electron)

### 1. MultiWindowRecorder Import

**Dosya:** `src/main/recording/index.ts`

```typescript
import MultiWindowRecorder from 'node-mac-recorder/MultiWindowRecorder';

// Global recorder instance
let currentMultiRecorder: MultiWindowRecorder | null = null;
```

### 2. IPC Handlers

**Dosya:** `src/main/ipc/recording-handlers.ts`

```typescript
import { ipcMain } from 'electron';
import MultiWindowRecorder from 'node-mac-recorder/MultiWindowRecorder';
import path from 'path';
import { app } from 'electron';

let multiRecorder: MultiWindowRecorder | null = null;

// Initialize Multi-Window Recorder
ipcMain.handle('recording:multi-window:init', async () => {
  if (multiRecorder) {
    multiRecorder.destroy();
  }

  multiRecorder = new MultiWindowRecorder({
    frameRate: 30,
    captureCursor: true,
    preferScreenCaptureKit: true
  });

  return { success: true };
});

// Add Window
ipcMain.handle('recording:multi-window:add', async (event, windowInfo) => {
  if (!multiRecorder) {
    throw new Error('Multi-recorder not initialized');
  }

  const index = await multiRecorder.addWindow(windowInfo);

  return {
    success: true,
    index,
    windowCount: multiRecorder.getWindowCount()
  };
});

// Remove Window
ipcMain.handle('recording:multi-window:remove', async (event, index) => {
  if (!multiRecorder) {
    throw new Error('Multi-recorder not initialized');
  }

  multiRecorder.removeWindow(index);

  return {
    success: true,
    windowCount: multiRecorder.getWindowCount()
  };
});

// Start Recording
ipcMain.handle('recording:multi-window:start', async () => {
  if (!multiRecorder) {
    throw new Error('Multi-recorder not initialized');
  }

  const outputDir = path.join(app.getPath('userData'), 'recordings', `rec_${Date.now()}`);

  // Create output directory
  const fs = require('fs');
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }

  const result = await multiRecorder.startRecording(outputDir);

  return {
    success: true,
    ...result
  };
});

// Stop Recording
ipcMain.handle('recording:multi-window:stop', async () => {
  if (!multiRecorder) {
    throw new Error('Multi-recorder not initialized');
  }

  const result = await multiRecorder.stopRecording();

  // Get CRVT metadata
  const crvtMetadata = multiRecorder.getMetadataForCRVT();

  return {
    success: true,
    ...result,
    crvtMetadata
  };
});

// Get Status
ipcMain.handle('recording:multi-window:status', async () => {
  if (!multiRecorder) {
    return { isRecording: false, windowCount: 0 };
  }

  return multiRecorder.getStatus();
});

// Cleanup
ipcMain.handle('recording:multi-window:destroy', async () => {
  if (multiRecorder) {
    multiRecorder.destroy();
    multiRecorder = null;
  }

  return { success: true };
});
```

## 🎨 Renderer Process (React)

### 1. Type Definitions

**Dosya:** `src/renderer/types/recording.ts`

```typescript
export interface WindowInfo {
  id: number;
  appName: string;
  title: string;
  width: number;
  height: number;
  x: number;
  y: number;
}

export interface MultiWindowRecordingState {
  windows: WindowInfo[];
  isRecording: boolean;
  outputFiles: string[];
  duration: number;
}
```

### 2. Recording Context/Store

**Dosya:** `src/renderer/contexts/RecordingContext.tsx`

```typescript
import React, { createContext, useContext, useState } from 'react';

interface RecordingContextType {
  selectedWindows: WindowInfo[];
  isRecording: boolean;
  addWindow: (window: WindowInfo) => Promise<void>;
  removeWindow: (index: number) => void;
  startRecording: () => Promise<void>;
  stopRecording: () => Promise<void>;
}

const RecordingContext = createContext<RecordingContextType | null>(null);

export const RecordingProvider: React.FC = ({ children }) => {
  const [selectedWindows, setSelectedWindows] = useState<WindowInfo[]>([]);
  const [isRecording, setIsRecording] = useState(false);

  const addWindow = async (window: WindowInfo) => {
    // Initialize if first window
    if (selectedWindows.length === 0) {
      await window.electron.invoke('recording:multi-window:init');
    }

    // Add window
    const result = await window.electron.invoke('recording:multi-window:add', window);

    if (result.success) {
      setSelectedWindows([...selectedWindows, window]);
    }
  };

  const removeWindow = async (index: number) => {
    await window.electron.invoke('recording:multi-window:remove', index);
    setSelectedWindows(selectedWindows.filter((_, i) => i !== index));
  };

  const startRecording = async () => {
    const result = await window.electron.invoke('recording:multi-window:start');

    if (result.success) {
      setIsRecording(true);
    }
  };

  const stopRecording = async () => {
    const result = await window.electron.invoke('recording:multi-window:stop');

    if (result.success) {
      setIsRecording(false);

      // Create CRVT file
      await createCRVTFile(result);

      // Open editor
      await openEditor(result.outputFiles[0]);
    }
  };

  return (
    <RecordingContext.Provider
      value={{
        selectedWindows,
        isRecording,
        addWindow,
        removeWindow,
        startRecording,
        stopRecording
      }}
    >
      {children}
    </RecordingContext.Provider>
  );
};

export const useRecording = () => {
  const context = useContext(RecordingContext);
  if (!context) {
    throw new Error('useRecording must be used within RecordingProvider');
  }
  return context;
};
```

### 3. Multi-Window Selector Component

**Dosya:** `src/renderer/components/recording/MultiWindowSelector.tsx`

```typescript
import React from 'react';
import { useRecording } from '../../contexts/RecordingContext';
import { WindowPreviewCard } from './WindowPreviewCard';

export const MultiWindowSelector: React.FC = () => {
  const { selectedWindows, addWindow, removeWindow, isRecording } = useRecording();

  const handleSelectWindow = async (index: number) => {
    // Show window picker overlay
    const pickedWindow = await window.electron.invoke('window-picker:show');

    if (pickedWindow) {
      if (index < selectedWindows.length) {
        // Replace existing
        removeWindow(index);
      }
      await addWindow(pickedWindow);
    }
  };

  return (
    <div className="multi-window-selector">
      <div className="selector-header">
        <h3>Kayıt Edilecek Pencereler</h3>
        <span className="window-count">{selectedWindows.length} pencere</span>
      </div>

      <div className="windows-grid">
        {/* Window Slot 1 */}
        <div className="window-slot">
          {selectedWindows[0] ? (
            <WindowPreviewCard
              window={selectedWindows[0]}
              onReselect={() => handleSelectWindow(0)}
              onRemove={() => removeWindow(0)}
              disabled={isRecording}
            />
          ) : (
            <button
              className="select-window-btn"
              onClick={() => handleSelectWindow(0)}
              disabled={isRecording}
            >
              <VideoIcon />
              <span>Pencere Seç</span>
            </button>
          )}
        </div>

        {/* Window Slot 2 - Show only if first window is selected */}
        {selectedWindows[0] && (
          <div className="window-slot">
            {selectedWindows[1] ? (
              <WindowPreviewCard
                window={selectedWindows[1]}
                onReselect={() => handleSelectWindow(1)}
                onRemove={() => removeWindow(1)}
                disabled={isRecording}
              />
            ) : (
              <button
                className="select-window-btn add-second"
                onClick={() => handleSelectWindow(1)}
                disabled={isRecording}
              >
                <PlusIcon />
                <span>İkinci Pencere Ekle</span>
              </button>
            )}
          </div>
        )}
      </div>
    </div>
  );
};
```

### 4. Window Preview Card

**Dosya:** `src/renderer/components/recording/WindowPreviewCard.tsx`

```typescript
import React from 'react';
import { WindowInfo } from '../../types/recording';

interface Props {
  window: WindowInfo;
  onReselect: () => void;
  onRemove: () => void;
  disabled?: boolean;
}

export const WindowPreviewCard: React.FC<Props> = ({
  window,
  onReselect,
  onRemove,
  disabled
}) => {
  return (
    <div className="window-preview-card">
      <div className="preview-header">
        <span className="app-name">{window.appName}</span>
        <button
          className="remove-btn"
          onClick={onRemove}
          disabled={disabled}
        >
          ×
        </button>
      </div>

      <div className="preview-content">
        {/* Thumbnail buraya gelecek */}
        <div className="window-icon">
          <VideoIcon />
        </div>
        <div className="window-info">
          <div className="window-title">{window.title || 'Başlıksız'}</div>
          <div className="window-size">{window.width} × {window.height}</div>
        </div>
      </div>

      <button
        className="reselect-btn"
        onClick={onReselect}
        disabled={disabled}
      >
        Değiştir
      </button>
    </div>
  );
};
```

### 5. Recording Controls

**Dosya:** `src/renderer/components/recording/RecordingControls.tsx`

```typescript
import React from 'react';
import { useRecording } from '../../contexts/RecordingContext';

export const RecordingControls: React.FC = () => {
  const { selectedWindows, isRecording, startRecording, stopRecording } = useRecording();

  const canStart = selectedWindows.length > 0 && !isRecording;

  return (
    <div className="recording-controls">
      {!isRecording ? (
        <button
          className="start-recording-btn"
          onClick={startRecording}
          disabled={!canStart}
        >
          <RecordIcon />
          <span>Kayıt Başlat</span>
          {selectedWindows.length > 1 && (
            <span className="window-badge">{selectedWindows.length} pencere</span>
          )}
        </button>
      ) : (
        <button
          className="stop-recording-btn"
          onClick={stopRecording}
        >
          <StopIcon />
          <span>Kaydı Durdur</span>
        </button>
      )}
    </div>
  );
};
```

## 📄 CRVT File Creation

**Dosya:** `src/main/utils/crvt-creator.ts`

```typescript
import fs from 'fs';
import path from 'path';

interface CRVTSegment {
  id: string;
  type: 'screen' | 'cursor' | 'audio' | 'camera';
  filePath: string;
  startTime: number;
  endTime: number;
  duration: number;
  windowIndex?: number;
  layoutRow?: number;
}

interface CRVTFile {
  version: string;
  timestamp: number;
  duration: number;
  segments: CRVTSegment[];
  multiWindow?: {
    enabled: boolean;
    windowCount: number;
    windows: Array<{
      index: number;
      appName: string;
      title: string;
      filePath: string;
      syncOffset: number;
    }>;
  };
}

export async function createMultiWindowCRVT(
  recordingResult: any,
  outputDir: string
): Promise<string> {
  const crvt: CRVTFile = {
    version: '2.0',
    timestamp: recordingResult.metadata.startTime,
    duration: recordingResult.duration,
    segments: [],
    multiWindow: {
      enabled: true,
      windowCount: recordingResult.windowCount,
      windows: []
    }
  };

  // Create segments for each window
  recordingResult.metadata.windows.forEach((win: any, index: number) => {
    // Screen segment
    crvt.segments.push({
      id: `screen_${index}_${Date.now()}`,
      type: 'screen',
      filePath: win.outputPath,
      startTime: 0,
      endTime: recordingResult.duration,
      duration: recordingResult.duration,
      windowIndex: index,
      layoutRow: index
    });

    // Cursor segment (if exists)
    const cursorFile = findCursorFile(win.outputPath);
    if (cursorFile && fs.existsSync(cursorFile)) {
      crvt.segments.push({
        id: `cursor_${index}_${Date.now()}`,
        type: 'cursor',
        filePath: cursorFile,
        startTime: 0,
        endTime: recordingResult.duration,
        duration: recordingResult.duration,
        windowIndex: index,
        layoutRow: index
      });
    }

    // Add window metadata
    crvt.multiWindow!.windows.push({
      index,
      appName: win.windowInfo.appName,
      title: win.windowInfo.title,
      filePath: win.outputPath,
      syncOffset: win.syncOffset
    });
  });

  // Save CRVT file
  const crvtPath = path.join(outputDir, 'recording.crvt');
  fs.writeFileSync(crvtPath, JSON.stringify(crvt, null, 2));

  console.log(`📄 CRVT file created: ${crvtPath}`);

  return crvtPath;
}

function findCursorFile(videoPath: string): string | null {
  const dir = path.dirname(videoPath);
  const basename = path.basename(videoPath, path.extname(videoPath));

  // Try to find cursor file
  const cursorPath = path.join(dir, `temp_cursor_${basename.split('_').pop()}.json`);

  return fs.existsSync(cursorPath) ? cursorPath : null;
}
```

## 🎬 Editor Integration

**Dosya:** `src/renderer/components/editor/MultiRowTimeline.tsx`

```typescript
import React, { useMemo } from 'react';
import { CRVTFile, CRVTSegment } from '../../types/crvt';
import { ClipSegment } from './ClipSegment';

interface Props {
  recording: CRVTFile;
  onSegmentSelect?: (segment: CRVTSegment) => void;
}

export const MultiRowTimeline: React.FC<Props> = ({
  recording,
  onSegmentSelect
}) => {
  // Group segments by layout row
  const segmentsByRow = useMemo(() => {
    const rows = new Map<number, CRVTSegment[]>();

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
          data-row={rowIndex}
        >
          <div className="row-label">
            <div className="row-number">Row {rowIndex + 1}</div>
            <div className="row-app-name">
              {recording.multiWindow?.windows[rowIndex]?.appName || `Window ${rowIndex + 1}`}
            </div>
          </div>

          <div className="row-track">
            {segments.map(segment => (
              <ClipSegment
                key={segment.id}
                segment={segment}
                totalDuration={recording.duration}
                onSelect={() => onSegmentSelect?.(segment)}
              />
            ))}
          </div>
        </div>
      ))}
    </div>
  );
};
```

## 🎨 CSS Styles

**Dosya:** `src/renderer/styles/multi-window.css`

```css
/* Multi-Window Selector */
.multi-window-selector {
  padding: 20px;
}

.selector-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 20px;
}

.window-count {
  font-size: 14px;
  color: #888;
}

.windows-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
  gap: 20px;
}

.window-slot {
  min-height: 200px;
}

.select-window-btn {
  width: 100%;
  height: 200px;
  border: 2px dashed #444;
  border-radius: 8px;
  background: transparent;
  color: #fff;
  cursor: pointer;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 12px;
  transition: all 0.2s;
}

.select-window-btn:hover {
  border-color: #666;
  background: rgba(255, 255, 255, 0.05);
}

.select-window-btn.add-second {
  border-color: #0066ff;
}

.select-window-btn.add-second:hover {
  background: rgba(0, 102, 255, 0.1);
}

/* Window Preview Card */
.window-preview-card {
  border: 1px solid #333;
  border-radius: 8px;
  background: #1a1a1a;
  overflow: hidden;
}

.preview-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 12px;
  border-bottom: 1px solid #333;
}

.app-name {
  font-weight: 600;
  color: #fff;
}

.remove-btn {
  width: 24px;
  height: 24px;
  border: none;
  background: #ff4444;
  color: #fff;
  border-radius: 4px;
  cursor: pointer;
  font-size: 18px;
  line-height: 1;
}

.preview-content {
  padding: 20px;
  text-align: center;
}

.window-info {
  margin-top: 12px;
}

.window-title {
  font-size: 14px;
  color: #ccc;
}

.window-size {
  font-size: 12px;
  color: #888;
  margin-top: 4px;
}

.reselect-btn {
  width: 100%;
  padding: 10px;
  border: none;
  border-top: 1px solid #333;
  background: transparent;
  color: #0066ff;
  cursor: pointer;
}

/* Recording Controls */
.start-recording-btn {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 16px 32px;
  background: #ff0000;
  color: #fff;
  border: none;
  border-radius: 8px;
  font-size: 16px;
  font-weight: 600;
  cursor: pointer;
}

.window-badge {
  padding: 4px 8px;
  background: rgba(255, 255, 255, 0.2);
  border-radius: 12px;
  font-size: 12px;
}

/* Multi-Row Timeline */
.multi-row-timeline {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 20px;
}

.timeline-row {
  display: flex;
  min-height: 80px;
  border: 1px solid #333;
  border-radius: 4px;
  background: #1a1a1a;
}

.row-label {
  width: 150px;
  padding: 12px;
  border-right: 1px solid #333;
  display: flex;
  flex-direction: column;
  gap: 4px;
}

.row-number {
  font-size: 12px;
  color: #888;
}

.row-app-name {
  font-weight: 600;
  color: #fff;
}

.row-track {
  flex: 1;
  position: relative;
  padding: 8px;
}
```

## 🚀 Kullanım Örneği

```typescript
// RecordingWindow.tsx
import React from 'react';
import { RecordingProvider } from './contexts/RecordingContext';
import { MultiWindowSelector } from './components/recording/MultiWindowSelector';
import { RecordingControls } from './components/recording/RecordingControls';

export const RecordingWindow: React.FC = () => {
  return (
    <RecordingProvider>
      <div className="recording-window">
        <h1>Yeni Kayıt</h1>

        <MultiWindowSelector />

        <RecordingControls />
      </div>
    </RecordingProvider>
  );
};
```

## ✅ Checklist

- [ ] MultiWindowRecorder import et
- [ ] IPC handlers ekle
- [ ] RecordingContext oluştur
- [ ] MultiWindowSelector komponenti
- [ ] WindowPreviewCard komponenti
- [ ] RecordingControls güncelle
- [ ] CRVT creator implement et
- [ ] MultiRowTimeline komponenti
- [ ] CSS stilleri ekle
- [ ] End-to-end test
