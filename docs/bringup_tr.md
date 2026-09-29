# ZCU208: tile 228, saat ve ILA ile chirp kontrolü

Adım adım İngilizce kart devreye alma rehberi (her adımda geçme kriteri ve
sorun giderme tablosu): [bringup.md](bringup.md).

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
  değerlerini okur. `cw`, `chirp` ve `nco_set`, 8x / I/Q / tam bant datapath
  dışındaki bir ayarda çalışmayı reddeder. Yalnızca tanı için:
  `set ::RFDC_CONFIG_CHECK 0`.
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
   referans 245.76 MHz, örnekleme 5898.24 MSPS, interpolation 8, fine mixer,
   I/Q -> Real, AXIS başına 8 adet 16-bit değer (4 kompleks örnek), 128-bit port,
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
interpolation **8x**, I/Q input **1**, datapath mode **0**, değişen heartbeat.
Raporlanan fabric word sayısını not et; bu değer henüz kartta doğrulanmadı.
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

## 3. ILA'da grafik

```tcl
source tcl/ila_capture.tcl
ila_capture out/chirp.csv
# CW için yükselen darbe kenarı beklemek yerine:
# ila_capture out/cw.csv immediate
```

4096 saatlik kayıt yaklaşık 22.22 us içerir; 4 örnek/saat ile 16384 kompleks
örnek elde edilir. Normal capture tüm saatleri alır; capture qualification veya
çoklu pencere ekleme, yoksa aralardaki süreyi CSV'den yeniden kurmak gerekir.

| ILA probu | İçerik |
|---|---|
| probe0 | 128-bit DAC giriş verisi |
| probe1 | darbe işareti (`mon_gate`, `trig_out` ile aynı) |
| probe2 / probe3 | TVALID / TREADY |
| probe4 / probe5 | I0 / Q0 |
| probe6 / probe7 | I1 / Q1 |
| probe8 / probe9 | I2 / Q2 |
| probe10 / probe11 | I3 / Q3 |

Vivado dalga penceresinde 16-bit probları seç: **Radix > Signed Decimal**,
**Waveform Style > Analog**. Tek bir lane yalnızca her dördüncü örneği gösterir;
400 MHz genişlikli chirp'i tek lane'den frekans olarak yorumlamak aliasing üretir.
Doğru zaman grafiği için tüm lane'leri birleştiren araç:

```sh
python -m pip install -r sim/requirements.txt
python scripts/plot_ila.py out/chirp.csv
```

`out/chirp.png` I/Q, darbe işareti ve anlık baseband frekansını gösterir.
Adları farklı bir CSV'de `--data-column`, `--gate-column`, `--valid-column`,
`--ready-column` ile tam sütun adlarını verebilirsin. Bilinmeyen veriler ve
TREADY/TVALID düşük satırlar hata sayılır; zaman ekseni satır silinerek sıkıştırılmaz.

**ILA, RFDC öncesi dijital I/Q verisini gösterir.** DAC'ın analog RF çıkışını,
PLL faz gürültüsünü, interpolation filtresini veya NCO taşıyıcısını ölçmez.
Fiziksel RF çıkışı osiloskop/spektrum analizörüyle ya da uygun seviyede DAC–ADC
loopback ve ADC yakalamasıyla doğrulanmalıdır. `trig_out` da DAC analog
gecikmesini içermeyen dijital darbe işaretidir.

## 4. Doğrulama sınırı ve kaynaklar

29 Eylül Verilator testinde 48.840 RTL örneği sıfır uyuşmazlıkla geçti; frekans/darbe analizinde
10/10 kontrol ve CSV ayrıştırıcısında 6/6 test başarılı oldu. Tcl kontrol
testleri de geçti. [Örnek grafik](chirp_interleaved_sim.png) RTL simülasyonudur.
Bu testler RTL örneklerini ve Tcl/Python davranışını sınar. RFDC/ILA IP
üretimi, synthesis, timing closure ve kart ölçümü Vivado + ZCU208 üzerinde
ayrıca çalıştırılmalıdır. Bu depoda yeni bir doğrulanmış bitstream verilmez.

- [AMD ZCU208 kart kılavuzu UG1410](https://docs.amd.com/api/khub/documents/ckCyYWZW28TiC5TY1lMC_Q/content)
- [AMD ZCU208 DAC228/ILA örneği, saat şeması](https://www.xilinx.com/publications/products/board-kits/zcu208-dds-ila-2020p2.pdf)
- [PG269 RF-DAC veri formatı](https://docs.amd.com/r/en-US/pg269-rf-data-converter/Interface-Data-Formats)
- [UG908 debug clock kuralları](https://docs.amd.com/r/en-US/ug908-vivado-programming-debugging/Debug-Cores-Clocking-Guidelines)
- [Üretim ZCU208 pin dosyası](https://github.com/Xilinx/XilinxBoardStore/blob/2022.2/boards/Xilinx/zcu208/production/2.0/part0_pins.xml)

