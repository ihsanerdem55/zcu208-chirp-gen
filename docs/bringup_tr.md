# ZCU208: tile 228, saat ve ILA ile chirp kontrolü

Adım adım İngilizce kart devreye alma rehberi (her adımda geçme kriteri ve
sorun giderme tablosu): [bringup.md](bringup.md).

## 1 Ekim: 4x interpolasyon ve inceleme düzeltmeleri

- **4x interpolasyon.** RF-DAC artık 5.89824 GSPS'de 4x interpolasyonla
  çalışır: RFDC girişi 1474.56 MSPS kompleks, 184.32 MHz fabric saatinde
  saat başına **8 kompleks örnek (256-bit AXI4-Stream, 16 word)**. Fabric saati
  değişmedi; NCO etrafında kullanılabilir bant ±0,4·fs_bb ≈ **±590 MHz
  (~1,18 GHz)**, yani önceki 8x tasarımın iki katı. Chirp ve gürültü
  bantları buna göre genişletilebilir. Eski `.bit`/`.ltx` ile çalışmaz;
  yeniden derle.
- **CDC kısıtı:** `noise_mode` biti `chirp_timing.xdc` içindeki max-delay/bus-skew
  listesinde yoktu; AXI→DAC geçişi kısıtsızdı. Eklendi.
- **Gürültü kaynağı zamanlaması:** dört seri 35-bit toplayıcı, ardışık lane
  seçimi ve değişken LFSR ilerletmesi tek 5,4 ns'lik çevrimdeydi. Artık her
  lane için kayıtlı `(m+1)·ninc` sabitiyle tek toplama, doğrudan seçim, sabit
  LFSR ilerletmesi ve iki aşamalı boru hattı var (8 lane'de bile daha sığ).
- **Tekrarlanabilirlik ve tohum:** her APPLY gürültüyü tohumdan yeniden başlatır;
  aynı `noise` komutu öncesinde ne çalışmış olursa olsun aynı örnekleri üretir.
  `noise ... -seed N` (PHASE0) başka, ilintisiz bir gerçekleme seçer.
- **Çalışırken yeniden yükleme:** genlik, I/Q swap, paketleme ve gürültü seçimi
  artık kapıyla birlikte boru hattında ilerler; yoldaki eski örnekler eski
  ayarlarla biter, iki dalga arasında tam bir sıfır blok vardır.
- `cw`/`chirp`/`noise`, RF bandı (NCO ± bant) 0 Hz'i veya 2949 MHz'i (ilk
  Nyquist bölgesi) aşarsa uyarır. `plot_ila.py` 8 lane ve 1474.56 MSPS
  varsayar (eski yakalamalar için `--lanes 4 --fs-bb 737.28e6`) ve ortalamalı
  spektrum çizer.
- **Timing (ilk 4x derleme WNS/TNS negatifti):** DSP çarpıcısı artık tüm iç
  registerlarıyla (A/B, M, P), sin/cos BRAM'i çıkış registeriyle çalışıyor;
  DSP ile RF-DAC arasına bir register daha eklendi, gürültü seçicisi düz
  AND-OR mux oldu, yüksek fanout'lu resetler registerlandı/kaldırıldı ve
  ILA'ya 2 giriş pipeline aşaması eklendi. Implementation, timing odaklı
  direktiflerle çalışıyor. Her çalıştırmadan sonra
  `vivado/zcu208_chirp/zcu208_chirp.runs/impl_1/timing_failing.txt` en kötü
  40 path'i listeler; timing yine tutmazsa bu dosyayı gönder. Çıkış gecikmesi
  7'den 11 saate (60 ns) çıktı, örnekler değişmedi.
- **Asıl timing hatası (ikinci derleme):** `timing_failing.txt`, DAC veri
  yolunun timing'i karşıladığını (en kötü +0,93 ns) gösterdi. Başarısız olan
  yalnızca 8 path vardı: `r_ctrl_reg[1]` (AXI) → `cw_mode_reg_rep*` (DAC),
  yaklaşık −1,05 ns. Implementation `cw_mode` registerını çoğaltmış, kopyalar
  CDC istisnasının dışında kalmıştı. Artık aktarım tek yüklü,
  `DONT_TOUCH` olan `cap_*` registerlarında bitiyor; jeneratör bunların DAC
  tarafındaki kopyasını kullanıyor ve XDC `cap_*`'ı hedefliyor.
- Ayrıntılar, testler ve donanımda kontrol edilecekler:
  [review_2026-10-01.md](review_2026-10-01.md).

## Düzeltilen sorunlar

- CLK104 referans girişinin tile 230'a bağlı olduğu varsayımı yanlıştı.
  Standart CLK104 konektör yolu DAC tile **228**'e gider. Tile **230** ayrıca
  harici SMA saat girişine sahiptir. Tasarım artık `DAC0`, `dac0_clk`,
  `clk_dac0`, `s0_axis_aclk`, `s00_axis`, `vout00` ve kontrol yazılımında tile
  indeksi **0** kullanır. Tile'lar arası saat dağıtımı gerekmiyor.
- RF-DAC I/Q girişinde düşük bitten başlayarak sıra **I0,Q0,I1,Q1,I2,Q2,I3,Q3**
  olmalıdır. Önceki varsayılan I0,I1,I2,I3,Q0,Q1,Q2,Q3 idi. `PACK_ILV=1` hem
  reset varsayılanı hem de kontrol komutlarının varsayılanı oldu.
- ILA kapalıydı ve eklenirken hata oluşursa sessizce siliniyordu. Artık normal
  ILA IP varsayılan olarak eklenir; oluşturma hataları derlemeyi durdurur.
- Debug hub, tile başlamasa da çalışan bağımsız **100 MHz AXI saatine** bağlanır.
  ILA örnekleme saati **184.32 MHz DAC fabric** saatidir. DAC saati yokken ILA
  örnek alamaz; bağımsız hub bağlantısı bu saati üretmez.
- RFDC yapılandırması ve adres haritasındaki hatalar artık uyarıyla geçilmez.
  **Düzeltme:** RFDC IP'de `DAC_NCO_Freq00` birimi **GHz**'dir (aralık −10..10).
  Önceki `1000.0` değeri Vivado'da doğrulama hatası veriyordu. Başlangıç NCO'su
  artık `0.5` (500 MHz); çalışma sırasında `nco_set` ile değiştirilir. Nyquist
  bölgesi IP varsayılanında (bölge 1) bırakıldı.
- Bekleyen APPLY varken yeni istek gönderilmez. CW/chirp değiştirilmeden önce
  mevcut akış kapatılır ve boru hattındaki eski örnekler boşaltılır.

## 29 Eylül inceleme düzeltmeleri

DAC resetinden sonra eski APPLY isteği artık tekrar uygulanmaz; çıkış kapalı
kalır ve yeni bir CW/chirp komutu gerekir. Bekleyen aktarım sırasında parametre
ve APPLY yazmaları donanımda SLVERR ile reddedilir. Sıfır WSTRB etkisizdir.
`gen_off`, RFDC hazır değilken de çalışan generator domain'ini kapatabilir;
`rfdc_restart` çıkışı kapalı bırakır. Saat tamamen durmuşsa kapatma onayı
alınamaz; timeout, çıkışın kapandığı anlamına gelmez.

CDC parametre yollarına süre/skew sınırı eklendi ve AXI reseti DAC resetine
bağlandı. Yeni bitstream üret, timing/CDC raporlarını kontrol et.
[İnceleme, test sonuçları ve kart kontrol listesi](review_2026-09-29.md).

## 29 Eylül ikinci inceleme (kart hazırlığı)

- **DAC MMCM reseti eksikti.** `clk_wiz_dac` girişi `rfdc/clk_dac0`,
  konfigürasyon anında yoktur ve her tile yeniden başlatmasında durur. MMCM,
  LOCKED düştükten sonra resetlenmelidir. Reset pini olmadığı için
  `rfdc_restart` veya geç yüklenen CLK104 profili; DAC fabric saatini, ILA'yı
  ve heartbeat'i yeniden programlamaya kadar durdurabiliyordu. Artık bağımsız
  AXI saatindeki denetleyici, kilit yokken ~2,6 ms'de bir 160 ns reset darbesi
  verir. Kilit 1,28 µs kararlı kalana kadar DAC reset denetleyicisini
  (`rst_dac/aux_reset_in`) resette tutar. **STATUS bit 3 = MMCM kilitli.**
- Saat kaybından sonra DAC domain'i her yeniden kilitlenmede resetlenir; eski
  dalga şekli kaldığı yerden devam edemez. Bu yüzden `rfdc_restart`, fabric
  saati zaten kaybolmuşken de güvenle çalışır.
- `run_hw_axi -quiet` başarısız işlemlerde bile TCL_OK döndürüyordu. Zaman
  aşımı, JTAG bağlantı kaybı ve SLVERR görünmüyordu. `-quiet` kaldırıldı; hata
  artık adresle birlikte bildirilir.
- `rfdc_status`; interpolation, I/Q giriş, datapath modu ve fabric word
  değerlerini okur. `cw`, `chirp` ve `nco_set`, beklenen interpolasyon
  (artık 4x) / I/Q / tam bant datapath dışındaki bir ayarda çalışmayı reddeder.
  Yalnızca tanı için: `set ::RFDC_CONFIG_CHECK 0`.
- `gen_off`, DAC domain'i resetteyken başarılı sayılır, çünkü reset enable'ı
  sıfırda tutar. Canlı ama onay vermeyen handshake ise hâlâ hatadır.

## 1. Saat ve proje

Bu ayarlar standart ZCU208 + CLK104 bağlantısını ve 245.76 MHz DAC referansını
varsayar. Başka bir saat kablolaması veya profil kullanıyorsan frekansı aynı
anda hem kartta hem RFDC IP'de değiştirmen gerekir.

1. CLK104 LMK04828 profilinde DAC referansına giden **DCLKout6** çıkışını
   **245.76 MHz** olarak etkinleştir. Yalnızca profil dosyasının adına bakmak
   yeterli değildir; kullanılan çıkışın frekansını ve enable durumunu kontrol et.
   Bu proje CLK104'ü programlamaz; BoardUI/System Controller kullanılır.
2. Vivado 2022.2 veya üzeri ve üretim ZCU208 board files gerekir. Depo kökünde:
   ```tcl
   source tcl/build_bd.tcl
   ```
3. RFDC IP'de tek DAC tile 228 / channel 0: PLL açık, yerel saat kaynağı tile 228,
   referans 245.76 MHz, örnekleme 5898.24 MSPS, interpolation 4, fine mixer,
   I/Q -> Real, AXIS başına 16 adet 16-bit değer (8 kompleks örnek), 256-bit port,
   AXIS ve çıkış saati 184.32 MHz. MTS kapalıdır.
4. Generate Bitstream çalıştır. `debug_hub.tcl` uygulama öncesi otomatik çalışır;
   hub için bağımsız `axi_clk_100m` ağını bulamazsa durur. Hook'u atlama.
5. Aynı derlemeden gelen `.bit` ve `.ltx` dosyalarını Hardware Manager'da seç.
   Gerekirse Refresh Device yap. JTAG hızını 10 MHz veya altına al.

`USER_SI570_C0` 300 MHz -> AXI Clock Wizard 100 MHz;
`CLK104` 245.76 MHz -> RFDC tile 228 PLL -> `clk_dac0` 184.32 MHz ->
DAC Clock Wizard -> chirp, RFDC AXIS ve ILA. DAC Clock Wizard'ın reseti,
AXI saatindeki `chirp_gen_0/dac_mmcm_reset` tarafından sürülür.
Kart pinleri üretim board store 2.0 dosyasına göre AP20/AP19, reset AU1,
LED0 AR19 olarak korunmuştur. Eski UG1410 revizyonundaki pin tablosu ile
üretim board dosyası farklılık gösterebilir; kendi kart revizyonunla eşleştir.

## 2. Önce saat, sonra sinyal

Hardware Manager Tcl konsolunda, depo kökünden:

```tcl
source tcl/chirp_ctrl.tcl
hw_init
rfdc_status
clock_check
```

Beklenen: tile **228**, state **15**, power-up **1**, PLL locked **1**,
DAC MMCM locked **1**, handshake ready **1**, APPLY pending **0**,
interpolation **4x**, I/Q input **1**, datapath mode **0**, değişen heartbeat.
Raporlanan fabric word sayısını not et (beklenen 16); bu değer henüz kartta
doğrulanmadı.
Heartbeat frekans ölçümü değildir; yalnızca fabric saatinin hareket ettiğini gösterir.

Saat profili bitstream'den sonra yüklendiyse:

```tcl
rfdc_restart
```

State 15'e ulaşmıyorsa önce referans frekansı/çıkış enable, PLL ayarı ve
`clk_wiz_dac` kilidini kontrol et. State 6 tek başına hatanın hangi kabloda
olduğunu kanıtlamaz. Tile state 15'te ama `DAC MMCM locked 0` ise donanım
MMCM resetini ~2,6 ms'de bir tekrarlar; durum kalıcıysa `clk_dac0`
frekansını ve RFDC fabric saat ayarını kontrol et. Eski tasarıma ait .bit/.ltx veya tile 230 bağlantısı
kullanılmadığından emin ol. APPLY timeout sonrası aynı APPLY'ı tekrar
çevirmek yerine saati düzelt; kurtarılamayan durumda yeniden programla.

İlk RF testi için 500 MHz merkez önerilen örnektir; tile 228 kanal 0'ın XM655
LF balun yolundaki 10 MHz–1 GHz bandı içinde kalır. 1.5 GHz merkez kullanacaksan
çıkış yolunun/balunun o bandı desteklediğini ayrıca doğrula.

```tcl
nco_set 500e6
cw 10e6 0.1
# Beklenen RF ton: yaklaşık 510 MHz. İlk ölçümde düşük genlikle başla.
chirp -bw 400e6 -pw 2e-6 -pri 10e-6 -amp 0.1
# Baseband: -200 .. +200 MHz; RF: yaklaşık 300 .. 700 MHz
# Yuvarlanmış süreler: PW 369 clock (~2.002 us), PRI 1843 clock (~9.999 us)
```

Geniş bant (4x ile ~1,18 GHz'e kadar): NCO'yu tüm RF bandı hem ilk Nyquist
bölgesine (0–2949 MHz) hem de çıkış yoluna sığacak yere koy. 500 MHz
örneklerindeki XM655 balunu yaklaşık 10 MHz–1 GHz'i kapsar; 1 GHz'lik bir
tarama için daha geniş bir yol gerekir.

```tcl
nco_set 1.5e9
chirp -bw 1e9 -pw 2e-6 -pri 10e-6 -amp 0.1   ;# RF 1.0 .. 2.0 GHz
```

### Band sınırlı gürültü

`noise` komutu, seçilen bant genişliğini sözde-rastgele örneklerle doldurur
(alıcı hassasiyeti/BER testi, gürültü figürü ve kalibrasyon ölçümleri). Aynı DAC
yolunu kullanır: merkez frekansı `nco_set`, seviyeyi `-amp` belirler, `gen_off`
durdurur.

```tcl
nco_set 500e6
noise -bw 200e6 -amp 0.1                       ;# sürekli, ~400..600 MHz
# noise -bw 100e6 -amp 0.1 -pw 2e-6 -pri 10e-6 ;# darbeli gürültü
# noise -bw 200e6 -amp 0.1 -seed 7             ;# başka bir gürültü gerçeklemesi
```

Her `D = fs_bb/bw` örnekte yeni bir rastgele değer çekilip aradaki örneklerde
tutulur (örnekle-tut), bu yüzden band ~±`bw`/2 genişliğinde (−3 dB) ve sinc²
zarflıdır (ilk sıfırlar ±`bw`). RFDC interpolasyon filtresi yaklaşık ±0.4·fs_bb
(±590 MHz) geçirir; ~1,18 GHz'e kadar bant kullanılabilir. Analizörde `Average`
ile merkez (~500 MHz) etrafında yükselen bir gürültü tabanı görülür.
`plot_ila.py` çıktısının en alttaki **Spectrum (dB)** paneli (ortalamalı spektrum)
bandı ve şeklini gösterir; anlık frekans paneli gürültüde anlamsızdır. Her
`noise` komutu diziyi tohumdan yeniden başlatır: aynı komut her zaman aynı
örnekleri üretir; `-seed` başka bir gerçekleme seçer.

## 3. ILA'da grafik

```tcl
source tcl/ila_capture.tcl
ila_capture out/chirp.csv
# CW için yükselen darbe kenarı beklemek yerine:
# ila_capture out/cw.csv immediate
```

4096 saatlik kayıt yaklaşık 22.22 us içerir; 8 örnek/saat ile 32768 kompleks
örnek elde edilir. Normal capture tüm saatleri alır; capture qualification veya
çoklu pencere ekleme, yoksa aralardaki süreyi CSV'den yeniden kurmak gerekir.

| ILA probu | İçerik |
|---|---|
| probe0 | 256-bit DAC giriş verisi |
| probe1 | darbe işareti (`mon_gate`, `trig_out` ile aynı) |
| probe2 / probe3 | TVALID / TREADY |
| probe4 / probe5 | I0 / Q0 |
| probe6 / probe7 | I1 / Q1 |
| … | … |
| probe18 / probe19 | I7 / Q7 |

Vivado dalga penceresinde 16-bit probları seç: **Radix > Signed Decimal**,
**Waveform Style > Analog**. Tek bir lane yalnızca her sekizinci örneği gösterir;
geniş bir chirp'i tek lane'den frekans olarak yorumlamak aliasing üretir.
Doğru zaman grafiği için tüm lane'leri birleştiren araç:

```sh
python -m pip install -r sim/requirements.txt
python scripts/plot_ila.py out/chirp.csv
```

`out/chirp.png` I/Q, darbe işareti, anlık baseband frekansı ve ortalamalı
spektrumu gösterir. Eski 8x derlemeden alınmış bir CSV için
`--lanes 4 --fs-bb 737.28e6` ver.
Adları farklı bir CSV'de `--data-column`, `--gate-column`, `--valid-column`,
`--ready-column` ile tam sütun adlarını verebilirsin. Bilinmeyen veriler ve
TREADY/TVALID düşük satırlar hata sayılır; zaman ekseni satır silinerek sıkıştırılmaz.

**ILA, RFDC öncesi dijital I/Q verisini gösterir.** DAC'ın analog RF çıkışını,
PLL faz gürültüsünü, interpolation filtresini veya NCO taşıyıcısını ölçmez.
Fiziksel RF çıkışı osiloskop/spektrum analizörüyle ya da uygun seviyede DAC–ADC
loopback ve ADC yakalamasıyla doğrulanmalıdır. `trig_out` da DAC analog
gecikmesini içermeyen dijital darbe işaretidir.

## 4. Doğrulama sınırı ve kaynaklar

1 Ekim'de (4x, 8 lane) Icarus ve Verilator'da 94.944 chirp örneği ve 148.184
gürültü örneği bit-exact modelle sıfır uyuşmazlıkla geçti; Python analizinde
14/14 kontrol, CSV ayrıştırıcısında 10/10 test ve Tcl kontrol testleri başarılı
oldu. [Örnek grafik](chirp_interleaved_sim.png) (1 GHz chirp) RTL simülasyonudur.
Bu testler RTL örneklerini ve Tcl/Python davranışını sınar. RFDC/ILA IP
üretimi, synthesis, timing closure ve kart ölçümü Vivado + ZCU208 üzerinde
ayrıca çalıştırılmalıdır. Bu depoda yeni bir doğrulanmış bitstream verilmez.

- [AMD ZCU208 kart kılavuzu UG1410](https://docs.amd.com/api/khub/documents/ckCyYWZW28TiC5TY1lMC_Q/content)
- [AMD ZCU208 DAC228/ILA örneği, saat şeması](https://www.xilinx.com/publications/products/board-kits/zcu208-dds-ila-2020p2.pdf)
- [PG269 RF-DAC veri formatı](https://docs.amd.com/r/en-US/pg269-rf-data-converter/Interface-Data-Formats)
- [UG908 debug clock kuralları](https://docs.amd.com/r/en-US/ug908-vivado-programming-debugging/Debug-Cores-Clocking-Guidelines)
- [Üretim ZCU208 pin dosyası](https://github.com/Xilinx/XilinxBoardStore/blob/2022.2/boards/Xilinx/zcu208/production/2.0/part0_pins.xml)

