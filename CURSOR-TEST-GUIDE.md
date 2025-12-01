# 🎯 Cursor Seed Discovery Test Rehberi

## Amaç
Loading ve resize cursor'larının doğru seed değerlerini keşfetmek ve hardcoded mapping'e eklemek.

## Test Adımları

### 1. Discovery Test'i Başlatın
```bash
node test-cursor-seeds.js
```

### 2. Fareyi Şu Alanlara Götürün (Her birini 3-5 saniye tutun)

#### ✅ Kolay Olanlar (Muhtemelen Çalışıyor):
- **Default Cursor**: Normal bir alan
- **Text Cursor**: Bu terminal veya bir text editor
- **Pointer Cursor**: Bir link veya buton üzerine

#### ⚠️ Problem Olanlar (Bunları Test Edin):
- **Resize Cursors**:
  - Bir pencere kenarına götürün (↔️ yatay resize)
  - Bir pencere köşesine götürün (↗️ diagonal resize)
  - Üst/alt kenarlara götürün (↕️ dikey resize)
  - **ÖNEMLİ**: Finder, Safari, Chrome gibi uygulamaların pencereleri

- **Loading/Wait Cursor**:
  - Safari'de ağır bir sayfa yükleyin
  - Bir uygulamayı başlatırken imleci üzerine götürün
  - Terminal'de uzun süren bir komut çalıştırın ve üzerine götürün

- **Progress Cursor**:
  - Dosya kopyalama sırasında Finder üzerinde
  - App Store'da indirme sırasında

### 3. Sonuçları Kontrol Edin

Test bittiğinde (veya Ctrl+C ile çıktığınızda) şöyle bir rapor göreceksiniz:

```
═══════════════════════════════════════════════════════════
📊 KEŞFEDİLEN CURSOR TİPLERİ VE SEED'LERİ
═══════════════════════════════════════════════════════════

🎯 DEFAULT
   Seed: 785683 (10 görülme)

🎯 TEXT
   Seed: 785684 (25 görülme)

🎯 EW-RESIZE
   Seed: 785690 (15 görülme)

🎯 NS-RESIZE
   Seed: 785691 (12 görülme)

... vb
```

### 4. Önemli Bilgiler

**Eğer bir cursor tipi yanlış gösteriliyorsa:**
- Seed değeri var AMA tip yanlış = Detection logic'i düzeltmemiz gerekli
- Seed değeri hiç bulunamıyor = macOS o cursor'ı farklı şekilde döndürüyor

**Beklenen Sonuç:**
Her farklı cursor tipi için farklı seed değerleri görmemiz gerekiyor.

## Sorun Giderme

### "Resize cursor yakalayamıyorum"
- Farklı uygulamalar deneyin (Safari, Chrome, Finder, VS Code)
- Pencere kenarlarına ve köşelerine dikkat edin
- Tam kenarda değil, biraz daha içerde olabilir resize cursor zone'u

### "Loading cursor bulamıyorum"
- Ağır bir web sayfası yükleyin (örn: YouTube)
- Büyük bir dosya kopyalayın
- Bir uygulamayı başlatırken fareyi üzerine götürün

### "Hep aynı seed geliyor"
- Seed'ler runtime'da değişiyor, bu normal
- Önemli olan seed learning'in çalışması (log'da `📝 Learned seed mapping` görmeli)

## Test Sonrası

Bulunan seed'leri bana gönderin, ben de hardcoded mapping'e ekleyeceğim veya detection logic'i düzelteceğim.

**Format:**
```
EW-RESIZE: 785690
NS-RESIZE: 785691
WAIT: 785695
PROGRESS: 785696
```
