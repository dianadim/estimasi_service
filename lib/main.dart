import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';

import 'package:excel/excel.dart' hide Border;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'firebase_options.dart';
import 'package:flutter/painting.dart' as flutter;
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

const String ecoSupabaseUrl =
    'https://vwqnrmdcmlgwnahlvuqt.supabase.co';
const String ecoSupabaseAnonKey = 'sb_publishable_2ir0HNOfCFt-zQEkfyvpsA_UYXRlrl3';

final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  await _localNotifications.initialize(
  settings: const InitializationSettings(
    android: androidInit,
  ),
);

  // URL project dibuat eksplisit agar APK tetap memiliki host Supabase
  // meskipun build tidak memakai --dart-define SUPABASE_URL.
  await Supabase.initialize(
    url: ecoSupabaseUrl,
    anonKey: ecoSupabaseAnonKey,
  );

  runApp(const EstimasiServiceApp());
}

const Color biruUtama = Color(0xFF005BAC);
const Color biruMuda = Color(0xFFEAF4FF);
const Color background = Color(0xFFF5F8FC);

class DatabaseItem {
  String kode;
  String nama;
  int harga;
  String tipeKendaraan;

  DatabaseItem({
    required this.kode,
    required this.nama,
    required this.harga,
    this.tipeKendaraan = '',
  });
}

enum KategoriEstimasi {
  jasa,
  sparePart,
  bahan,
}

class ItemEstimasi {
  final String id;
  final String kode;
  final String nama;
  final int harga;
  final KategoriEstimasi kategori;
  final String tipeKendaraan;

  double qty;
  double diskonPersen;

  ItemEstimasi({
    required this.id,
    required this.kode,
    required this.nama,
    required this.harga,
    required this.kategori,
    this.tipeKendaraan = '',
    this.qty = 1,
    this.diskonPersen = 0,
  });

  double get subtotal => harga * qty;
  double get nominalDiskon => subtotal * diskonPersen / 100;
  double get total => subtotal - nominalDiskon;
}

class EstimasiServiceApp extends StatelessWidget {
  const EstimasiServiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Estimasi Service',
      builder: (context, child) {
        final media = MediaQuery.of(context);
        final isPhone = media.size.width < 600;
        return MediaQuery(
          data: media.copyWith(
            textScaler: TextScaler.linear(isPhone ? 0.82 : 1.0),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: biruUtama,
          primary: biruUtama,
        ),
        scaffoldBackgroundColor: background,
        appBarTheme: const AppBarTheme(
          backgroundColor: biruUtama,
          foregroundColor: Colors.white,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(
              color: Color(0xFFD8E2EE),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(
              color: biruUtama,
              width: 2,
            ),
          ),
        ),
      ),
      home: const EstimasiPage(),
    );
  }
}

class _InfoHeader extends StatelessWidget {
  final IconData icon;
  final String text;
  const _InfoHeader(this.icon, this.text);
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
    Icon(icon, color: Colors.white, size: 19),
    const SizedBox(width: 7),
    Flexible(child: Text(text, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600))),
  ]);
}

class EstimasiPage extends StatefulWidget {
  const EstimasiPage({super.key});

  @override
  State<EstimasiPage> createState() => _EstimasiPageState();
}

class _EstimasiPageState extends State<EstimasiPage> {
  int _tabAktif = 0;

  // Master Spare Part/Bahan cloud + cache lokal.
  static const String _kCloudSparePart = 'eco_cloud_sparepart_cache_v1';
  static const String _kCloudBahan = 'eco_cloud_bahan_cache_v1';
  static const String _kCloudSparePartVersion = 'eco_cloud_sparepart_version_v1';
  static const String _kCloudBahanVersion = 'eco_cloud_bahan_version_v1';
  bool _sinkronMasterBerjalan = false;
  Database? _masterDb;
  bool _masterLokalSiap = false;
  int _jumlahSparePartLokal = 0;
  int _jumlahBahanLokal = 0;

  // ECO / Temuan Service - tahap 1 (penyimpanan lokal)
  static const String _kunciEcoEstimasi = 'eco_estimasi_sa_v1';
  final List<Map<String, dynamic>> ecoEstimasi = [];
  RealtimeChannel? _ecoFindingsChannel;
  static const String _kSaAktif = 'eco_sa_aktif_v1';
  String _saIdAktif = 'sa1';

  String get _labelSaAktif {
    switch (_saIdAktif) {
      case 'sa2':
        return 'SA 2';
      case 'sa3':
        return 'SA 3';
      default:
        return 'SA 1';
    }
  }

  Future<void> _muatSaAktif() async {
    final prefs = await SharedPreferences.getInstance();
    _saIdAktif = prefs.getString(_kSaAktif) ?? 'sa1';
  }

  Future<void> _pilihSaAktif() async {
    final hasil = await showDialog<String>(
      context: context,
      builder: (dc) => SimpleDialog(
        title: const Text('Pilih Service Advisor perangkat ini'),
        children: [
          SimpleDialogOption(onPressed: () => Navigator.pop(dc, 'sa1'), child: const ListTile(leading: Icon(Icons.person), title: Text('SA 1'))),
          SimpleDialogOption(onPressed: () => Navigator.pop(dc, 'sa2'), child: const ListTile(leading: Icon(Icons.person), title: Text('SA 2'))),
          SimpleDialogOption(onPressed: () => Navigator.pop(dc, 'sa3'), child: const ListTile(leading: Icon(Icons.person), title: Text('SA 3'))),
        ],
      ),
    );
    if (hasil == null || hasil == _saIdAktif) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSaAktif, hasil);
    if (!mounted) return;
    setState(() => _saIdAktif = hasil);
    await _siapkanNotifikasiSa();
    await _sinkronTemuanCloud();
  }

  final namaCustomerController = TextEditingController();
  final noPolisiController = TextEditingController();
  final noTeleponController = TextEditingController();
  final kilometerController = TextEditingController();
  final tipeKendaraanController = TextEditingController();
  final noRangkaController = TextEditingController();

  static const String _kTemplateWaTemuan = 'template_wa_temuan_v1';
  static const String _templateWaTemuanDefault = '''Halo Bapak/Ibu {nama},

Kami informasikan hasil pemeriksaan kendaraan:
Kendaraan: {tipe}
Nomor Polisi: {nopol}

Temuan pemeriksaan:
{temuan}

Total estimasi: {total}

PDF estimasi dan lampiran temuan kami sertakan untuk dapat diperiksa. Mohon konfirmasi apabila pekerjaan tersebut disetujui.

Terima kasih.
{sa} - Service Advisor''';
  final templateWaTemuanController = TextEditingController(text: _templateWaTemuanDefault);

  final namaServiceAdvisorController = TextEditingController(text: 'Dian Adim Jaya');
  final noWaServiceAdvisorController = TextEditingController(text: '089656500965');
  final namaRekeningController = TextEditingController(text: 'PT. ASTRA INTERNATIONAL Tbk');
  final namaBankController = TextEditingController(text: 'PERMATA');
  final nomorRekeningController = TextEditingController(text: '420 926 7255');

  final operationalNumberController = TextEditingController();
  final namaSa1Controller = TextEditingController(text: 'DIAN');
  final linkSa1Controller = TextEditingController();
  final namaSa2Controller = TextEditingController(text: 'DENDI');
  final linkSa2Controller = TextEditingController();
  final namaSa3Controller = TextEditingController(text: 'ASEP');
  final linkSa3Controller = TextEditingController();
  int saSpreadsheetTerpilih = 1;
  bool sedangUpdateSpreadsheet = false;
  bool sedangAmbilCustomer = false;

  final List<DatabaseItem> jasaDatabase = [];
  final List<DatabaseItem> spareParts = [];
  final List<DatabaseItem> bahan = [];
  final List<ItemEstimasi> itemEstimasi = [];

  bool loadingExcel = true;
  bool tampilkanDiskon = false;
  double diskonAkhirJasaPersen = 0;
  double diskonAkhirSparePartPersen = 0;
  double diskonAkhirBahanPersen = 0;
  double diskonGrandPersen = 0;
  String statusExcel = 'Membaca database Excel...';

  @override
  void initState() {
    super.initState();
    _muatAwal();
  }

  Future<void> _muatAwal() async {
    await _bukaMasterDb();
    await loadDatabaseManual();
    await _muatTemplateWaTemuan();
    await loadPengaturanSpreadsheet();
    await _muatSaAktif();
    await _loadEcoEstimasi();
    await _siapkanNotifikasiSa();
    await _sinkronTemuanCloud();
    _dengarkanTemuanRealtime();

    final masterKosong =
        _jumlahSparePartLokal == 0 || _jumlahBahanLokal == 0;

    if (mounted) {
      setState(() {
        loadingExcel = false;
        statusExcel = masterKosong
            ? 'Master lokal kosong • sinkronisasi pertama...'
            : 'Master lokal • $_jumlahSparePartLokal Spare Part • $_jumlahBahanLokal Bahan';
      });
    }

    if (masterKosong) {
      // Instalasi pertama: wajib isi SQLite sekarang.
      unawaited(_sinkronMasterCloud(paksa: true, tampilkanPesan: true));
    } else {
      // Pembukaan berikutnya: UI langsung siap, cek perubahan di background.
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) unawaited(_sinkronMasterCloud());
      });
    }
  }

  Future<void> _bukaMasterDb() async {
    final dbPath = p.join(await getDatabasesPath(), 'eco_master_estimasi.db');
    _masterDb = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE sparepart (kode_part TEXT PRIMARY KEY, nama_part TEXT NOT NULL, tipe_kendaraan TEXT NOT NULL DEFAULT \'\', harga INTEGER NOT NULL DEFAULT 0)',
        );
        await db.execute(
          'CREATE TABLE bahan (kode TEXT PRIMARY KEY, nama TEXT NOT NULL, harga INTEGER NOT NULL DEFAULT 0)',
        );
        await db.execute(
          'CREATE INDEX idx_sparepart_nama ON sparepart(nama_part COLLATE NOCASE)',
        );
        await db.execute(
          'CREATE INDEX idx_sparepart_tipe ON sparepart(tipe_kendaraan COLLATE NOCASE)',
        );
        await db.execute(
          'CREATE INDEX idx_bahan_nama ON bahan(nama COLLATE NOCASE)',
        );
      },
    );
    await _refreshJumlahMasterLokal();
    _masterLokalSiap = true;
  }

  Future<void> _refreshJumlahMasterLokal() async {
    final db = _masterDb;
    if (db == null) return;
    _jumlahSparePartLokal = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM sparepart'),
        ) ?? 0;
    _jumlahBahanLokal = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM bahan'),
        ) ?? 0;
  }

  Future<List<DatabaseItem>> _cariMasterLokal(
    KategoriEstimasi kategori,
    String keyword,
  ) async {
    final db = _masterDb;
    final q = keyword.trim();
    if (db == null || q.isEmpty) return [];
    final like = '%$q%';

    if (kategori == KategoriEstimasi.sparePart) {
      final rows = await db.query(
        'sparepart',
        columns: ['kode_part', 'nama_part', 'tipe_kendaraan', 'harga'],
        where:
            'kode_part LIKE ? COLLATE NOCASE OR nama_part LIKE ? COLLATE NOCASE OR tipe_kendaraan LIKE ? COLLATE NOCASE',
        whereArgs: [like, like, like],
        limit: 50,
      );
      return rows.map((e) => DatabaseItem(
        kode: (e['kode_part'] ?? '').toString(),
        nama: (e['nama_part'] ?? '').toString(),
        harga: (e['harga'] as num?)?.toInt() ?? 0,
        tipeKendaraan: (e['tipe_kendaraan'] ?? '').toString(),
      )).toList();
    }

    final rows = await db.query(
      'bahan',
      columns: ['kode', 'nama', 'harga'],
      where: 'kode LIKE ? COLLATE NOCASE OR nama LIKE ? COLLATE NOCASE',
      whereArgs: [like, like],
      limit: 50,
    );
    return rows.map((e) => DatabaseItem(
      kode: (e['kode'] ?? '').toString(),
      nama: (e['nama'] ?? '').toString(),
      harga: (e['harga'] as num?)?.toInt() ?? 0,
    )).toList();
  }

  void bukaPencarianMasterLokal(String judul, KategoriEstimasi kategori) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        var hasil = <DatabaseItem>[];
        var loading = false;
        var serial = 0;
        return StatefulBuilder(
          builder: (context, setD) => Dialog(
            insetPadding: const EdgeInsets.all(16),
            child: SizedBox(
              width: MediaQuery.sizeOf(dialogContext).width < 720
                  ? MediaQuery.sizeOf(dialogContext).width - 32 : 680,
              height: MediaQuery.sizeOf(dialogContext).height < 700
                  ? MediaQuery.sizeOf(dialogContext).height * 0.78 : 650,
              child: Column(children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  color: biruUtama,
                  child: Text(judul, style: const TextStyle(
                    color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    autofocus: true,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      labelText: kategori == KategoriEstimasi.sparePart
                          ? 'Cari kode, nama part, atau tipe kendaraan'
                          : 'Cari kode atau nama bahan',
                    ),
                    onChanged: (value) async {
                      final mySerial = ++serial;
                      final q = value.trim();
                      if (q.isEmpty) {
                        setD(() { hasil = []; loading = false; });
                        return;
                      }
                      setD(() => loading = true);
                      final data = await _cariMasterLokal(kategori, q);
                      if (!dialogContext.mounted || mySerial != serial) return;
                      setD(() { hasil = data; loading = false; });
                    },
                  ),
                ),
                Expanded(
                  child: loading
                      ? const Center(child: CircularProgressIndicator())
                      : hasil.isEmpty
                          ? const Center(child: Text('Ketik kata kunci untuk mencari'))
                          : ListView.separated(
                              itemCount: hasil.length,
                              separatorBuilder: (_, __) => const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final item = hasil[i];
                                return ListTile(
                                  title: Text(item.nama,
                                    style: const TextStyle(fontWeight: FontWeight.bold)),
                                  subtitle: Text(
                                    kategori == KategoriEstimasi.sparePart &&
                                            item.tipeKendaraan.isNotEmpty
                                        ? 'Kode: ${item.kode}\nTipe Kendaraan: ${item.tipeKendaraan}'
                                        : 'Kode: ${item.kode}',
                                  ),
                                  trailing: Text(rupiah(item.harga.toDouble())),
                                  onTap: () {
                                    tambahDatabaseItem(item, kategori);
                                    Navigator.pop(dialogContext);
                                  },
                                );
                              },
                            ),
                ),
              ]),
            ),
          ),
        );
      },
    );
  }

  Future<List<Map<String, dynamic>>> _ambilSemuaBaris(
    String tabel,
    String kolom,
  ) async {
    const ukuranHalaman = 1000;
    final hasil = <Map<String, dynamic>>[];
    var mulai = 0;
    while (true) {
      final response = await Supabase.instance.client
          .from(tabel)
          .select(kolom)
          .range(mulai, mulai + ukuranHalaman - 1);
      final page = (response as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      hasil.addAll(page);
      if (page.length < ukuranHalaman) break;
      mulai += ukuranHalaman;
    }
    return hasil;
  }

  Future<void> _simpanCacheMasterSaatIni() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kCloudSparePart,
      jsonEncode(spareParts.map((e) => {
        'kode_part': e.kode,
        'nama_part': e.nama,
        'tipe_kendaraan': e.tipeKendaraan,
        'harga': e.harga,
      }).toList()),
    );
    await prefs.setString(
      _kCloudBahan,
      jsonEncode(bahan.map((e) => {
        'kode': e.kode,
        'nama': e.nama,
        'harga': e.harga,
      }).toList()),
    );
  }

  Future<String> _versiMasterServer(String tabel) async {
    final response = await Supabase.instance.client
        .from(tabel)
        .select('updated_at')
        .order('updated_at', ascending: false)
        .limit(1);
    final rows = (response as List);
    if (rows.isEmpty) return '';
    final row = Map<String, dynamic>.from(rows.first as Map);
    return (row['updated_at'] ?? '').toString();
  }

  Future<bool> _masterCloudBerubah() async {
    final prefs = await SharedPreferences.getInstance();

    // Dua query kecil saja: masing-masing mengambil 1 baris updated_at terbaru.
    final versions = await Future.wait([
      _versiMasterServer('eco_master_sparepart'),
      _versiMasterServer('eco_master_bahan'),
    ]);

    final serverSp = versions[0];
    final serverBh = versions[1];
    final localSp = prefs.getString(_kCloudSparePartVersion) ?? '';
    final localBh = prefs.getString(_kCloudBahanVersion) ?? '';

    // Jika cache belum pernah punya versi, lakukan sinkron penuh sekali.
    return serverSp != localSp || serverBh != localBh;
  }

  Future<void> _sinkronMasterCloud({
    bool paksa = false,
    bool tampilkanPesan = false,
  }) async {
    if (_sinkronMasterBerjalan || !_masterLokalSiap) return;
    _sinkronMasterBerjalan = true;

    if (mounted && tampilkanPesan) {
      setState(() => statusExcel = 'Mengunduh master dari cloud...');
    }

    try {
      await _refreshJumlahMasterLokal();
      final kosong = _jumlahSparePartLokal == 0 || _jumlahBahanLokal == 0;
      final berubah = paksa || kosong || await _masterCloudBerubah();

      if (!berubah) {
        debugPrint('MASTER CLOUD: tidak berubah; SQLite lokal dipakai.');
        return;
      }

      final hasil = await Future.wait([
        _ambilSemuaBaris(
          'eco_master_sparepart',
          'kode_part,nama_part,tipe_kendaraan,harga',
        ),
        _ambilSemuaBaris(
          'eco_master_bahan',
          'kode,nama,harga',
        ),
      ]);

      final spRaw = hasil[0];
      final bhRaw = hasil[1];

      // Jangan pernah menghapus master lama bila download gagal/tidak lengkap.
      if (spRaw.isEmpty || bhRaw.isEmpty) {
        throw Exception(
          'Master cloud belum berhasil diunduh. '
          'Spare Part: ${spRaw.length}, Bahan: ${bhRaw.length}',
        );
      }

      if (mounted && tampilkanPesan) {
        setState(() {
          statusExcel =
              'Menyimpan ${spRaw.length} Spare Part • ${bhRaw.length} Bahan...';
        });
      }

      final db = _masterDb!;

      // Tulis ke tabel staging lebih dulu. Master aktif tidak disentuh
      // sampai seluruh data baru berhasil disimpan.
      await db.transaction((txn) async {
        await txn.execute('DROP TABLE IF EXISTS sparepart_sync');
        await txn.execute('DROP TABLE IF EXISTS bahan_sync');

        await txn.execute(
          "CREATE TABLE sparepart_sync ("
          "kode_part TEXT PRIMARY KEY, "
          "nama_part TEXT NOT NULL, "
          "tipe_kendaraan TEXT NOT NULL DEFAULT '', "
          "harga INTEGER NOT NULL DEFAULT 0"
          ")",
        );
        await txn.execute(
          "CREATE TABLE bahan_sync ("
          "kode TEXT PRIMARY KEY, "
          "nama TEXT NOT NULL, "
          "harga INTEGER NOT NULL DEFAULT 0"
          ")",
        );

        var batch = txn.batch();
        var n = 0;

        for (final e in spRaw) {
          final kode = (e['kode_part'] ?? '').toString().trim();
          final nama = (e['nama_part'] ?? '').toString().trim();
          if (kode.isEmpty && nama.isEmpty) continue;

          batch.insert(
            'sparepart_sync',
            {
              'kode_part': kode,
              'nama_part': nama,
              'tipe_kendaraan':
                  (e['tipe_kendaraan'] ?? '').toString().trim(),
              'harga': (e['harga'] as num?)?.toInt() ?? 0,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );

          n++;
          if (n % 500 == 0) {
            await batch.commit(noResult: true);
            batch = txn.batch();
          }
        }
        await batch.commit(noResult: true);

        batch = txn.batch();
        for (final e in bhRaw) {
          final kode = (e['kode'] ?? '').toString().trim();
          final nama = (e['nama'] ?? '').toString().trim();
          if (kode.isEmpty && nama.isEmpty) continue;

          batch.insert(
            'bahan_sync',
            {
              'kode': kode,
              'nama': nama,
              'harga': (e['harga'] as num?)?.toInt() ?? 0,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);

        final spCount = Sqflite.firstIntValue(
              await txn.rawQuery('SELECT COUNT(*) FROM sparepart_sync'),
            ) ??
            0;
        final bhCount = Sqflite.firstIntValue(
              await txn.rawQuery('SELECT COUNT(*) FROM bahan_sync'),
            ) ??
            0;

        if (spCount == 0 || bhCount == 0) {
          throw Exception(
            'Data staging kosong. Spare Part: $spCount, Bahan: $bhCount',
          );
        }

        // Baru setelah staging valid, ganti master lokal secara atomik.
        await txn.delete('sparepart');
        await txn.delete('bahan');

        await txn.execute(
          'INSERT OR REPLACE INTO sparepart '
          '(kode_part,nama_part,tipe_kendaraan,harga) '
          'SELECT kode_part,nama_part,tipe_kendaraan,harga '
          'FROM sparepart_sync',
        );
        await txn.execute(
          'INSERT OR REPLACE INTO bahan (kode,nama,harga) '
          'SELECT kode,nama,harga FROM bahan_sync',
        );

        await txn.execute('DROP TABLE sparepart_sync');
        await txn.execute('DROP TABLE bahan_sync');
      });

      final versions = await Future.wait([
        _versiMasterServer('eco_master_sparepart'),
        _versiMasterServer('eco_master_bahan'),
      ]);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCloudSparePartVersion, versions[0]);
      await prefs.setString(_kCloudBahanVersion, versions[1]);

      // Bersihkan cache JSON besar dari versi lama.
      await prefs.remove(_kCloudSparePart);
      await prefs.remove(_kCloudBahan);

      await _refreshJumlahMasterLokal();

      if (!mounted) return;
      setState(() {
        statusExcel =
            'Master lokal • $_jumlahSparePartLokal Spare Part • $_jumlahBahanLokal Bahan';
      });

      if (tampilkanPesan) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Sinkronisasi selesai: $_jumlahSparePartLokal Spare Part '
              'dan $_jumlahBahanLokal Bahan.',
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint('SINKRON MASTER CLOUD ERROR: $e');

      await _refreshJumlahMasterLokal();

      if (mounted) {
        setState(() {
          statusExcel = _jumlahSparePartLokal > 0
              ? 'Master lokal • $_jumlahSparePartLokal Spare Part • '
                  '$_jumlahBahanLokal Bahan • cloud gagal diperbarui'
              : 'Sinkronisasi master gagal • tekan Sinkron Master';
        });

        if (tampilkanPesan) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Sinkronisasi master gagal: $e'),
              duration: const Duration(seconds: 6),
            ),
          );
        }
      }
    } finally {
      _sinkronMasterBerjalan = false;
    }
  }

  Future<void> sinkronMasterManual() async {
    await _sinkronMasterCloud(paksa: true, tampilkanPesan: true);
  }

  Future<void> _simpanItemMasterCloud(int tab, DatabaseItem? lama, DatabaseItem baru) async {
    final client = Supabase.instance.client;
    if (tab == 1) {
      if (lama == null) {
        await client.from('eco_master_sparepart').insert({
          'kode_part': baru.kode,
          'nama_part': baru.nama,
          'tipe_kendaraan': baru.tipeKendaraan,
          'harga': baru.harga,
        });
      } else {
        var q = client.from('eco_master_sparepart').update({
          'kode_part': baru.kode,
          'nama_part': baru.nama,
          'tipe_kendaraan': baru.tipeKendaraan,
          'harga': baru.harga,
        }).eq('kode_part', lama.kode);
        if (lama.tipeKendaraan.isNotEmpty) {
          q = q.eq('tipe_kendaraan', lama.tipeKendaraan);
        }
        await q;
      }
    } else if (tab == 2) {
      if (lama == null) {
        await client.from('eco_master_bahan').insert({
          'kode': baru.kode,
          'nama': baru.nama,
          'harga': baru.harga,
        });
      } else {
        await client.from('eco_master_bahan').update({
          'kode': baru.kode,
          'nama': baru.nama,
          'harga': baru.harga,
        }).eq('kode', lama.kode);
      }
    }
  }

  Future<void> _hapusItemMasterCloud(int tab, DatabaseItem item) async {
    final client = Supabase.instance.client;
    if (tab == 1) {
      var q = client.from('eco_master_sparepart').delete().eq('kode_part', item.kode);
      if (item.tipeKendaraan.isNotEmpty) {
        q = q.eq('tipe_kendaraan', item.tipeKendaraan);
      }
      await q;
    } else if (tab == 2) {
      await client.from('eco_master_bahan').delete().eq('kode', item.kode);
    }
  }

  @override
  void dispose() {
    namaCustomerController.dispose();
    noPolisiController.dispose();
    noTeleponController.dispose();
    kilometerController.dispose();
    tipeKendaraanController.dispose();
    noRangkaController.dispose();
    templateWaTemuanController.dispose();
    namaServiceAdvisorController.dispose();
    noWaServiceAdvisorController.dispose();
    namaRekeningController.dispose();
    namaBankController.dispose();
    nomorRekeningController.dispose();
    unawaited(_masterDb?.close());
    operationalNumberController.dispose();
    namaSa1Controller.dispose();
    linkSa1Controller.dispose();
    namaSa2Controller.dispose();
    linkSa2Controller.dispose();
    namaSa3Controller.dispose();
    linkSa3Controller.dispose();
    if (_ecoFindingsChannel != null) {
      unawaited(Supabase.instance.client.removeChannel(_ecoFindingsChannel!));
    }
    super.dispose();
  }

  static const String _kSa1Nama = 'spreadsheet_sa1_nama_v1';
  static const String _kSa1Link = 'spreadsheet_sa1_link_v1';
  static const String _kSa2Nama = 'spreadsheet_sa2_nama_v1';
  static const String _kSa2Link = 'spreadsheet_sa2_link_v1';
  static const String _kSa3Nama = 'spreadsheet_sa3_nama_v1';
  static const String _kSa3Link = 'spreadsheet_sa3_link_v1';

  Future<void> loadPengaturanSpreadsheet() async {
    final prefs = await SharedPreferences.getInstance();
    namaSa1Controller.text = prefs.getString(_kSa1Nama) ?? 'DIAN';
    linkSa1Controller.text = prefs.getString(_kSa1Link) ?? '';
    namaSa2Controller.text = prefs.getString(_kSa2Nama) ?? 'DENDI';
    linkSa2Controller.text = prefs.getString(_kSa2Link) ?? '';
    namaSa3Controller.text = prefs.getString(_kSa3Nama) ?? 'ASEP';
    linkSa3Controller.text = prefs.getString(_kSa3Link) ?? '';
    if (mounted) setState(() {});
  }

  Future<void> simpanPengaturanSpreadsheet() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSa1Nama, namaSa1Controller.text.trim());
    await prefs.setString(_kSa1Link, linkSa1Controller.text.trim());
    await prefs.setString(_kSa2Nama, namaSa2Controller.text.trim());
    await prefs.setString(_kSa2Link, linkSa2Controller.text.trim());
    await prefs.setString(_kSa3Nama, namaSa3Controller.text.trim());
    await prefs.setString(_kSa3Link, linkSa3Controller.text.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Pengaturan Spreadsheet tersimpan')),
    );
  }

  TextEditingController get _namaSaSpreadsheetAktif {
    switch (saSpreadsheetTerpilih) {
      case 2:
        return namaSa2Controller;
      case 3:
        return namaSa3Controller;
      default:
        return namaSa1Controller;
    }
  }

  TextEditingController get _linkSaSpreadsheetAktif {
    switch (saSpreadsheetTerpilih) {
      case 2:
        return linkSa2Controller;
      case 3:
        return linkSa3Controller;
      default:
        return linkSa1Controller;
    }
  }

  Future<void> ambilCustomerSpreadsheet() async {
    final endpointDasar = _linkSaSpreadsheetAktif.text.trim();

    if (endpointDasar.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Link Spreadsheet SA belum diisi di pengaturan'),
        ),
      );
      return;
    }

    setState(() => sedangAmbilCustomer = true);

    try {
      final uriDasar = Uri.parse(endpointDasar);
      final uri = uriDasar.replace(
        queryParameters: {
          ...uriDasar.queryParameters,
          'action': 'customer',
        },
      );

      final response = await http.get(uri);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}');
      }

      final body = jsonDecode(response.body);
      if (body is! Map) {
        throw Exception('Format respons customer tidak valid');
      }

      final data = Map<String, dynamic>.from(body);
      if (data['success'] != true) {
        throw Exception(
          (data['message'] ?? 'Data customer tidak ditemukan').toString(),
        );
      }

      final rawCustomer = data['customer'];
      if (rawCustomer is! Map) {
        throw Exception('Data customer tidak tersedia');
      }

      final customer = Map<String, dynamic>.from(rawCustomer);

      if (!mounted) return;
      setState(() {
        namaCustomerController.text =
            (customer['namaCustomer'] ?? '').toString();
        noPolisiController.text =
            (customer['noPolisi'] ?? '').toString();
        noTeleponController.text =
            (customer['noTelepon'] ?? '').toString();
        kilometerController.text =
            (customer['kilometer'] ?? '').toString();
        tipeKendaraanController.text =
            (customer['tipeKendaraan'] ?? '').toString();
        noRangkaController.text =
            (customer['noRangka'] ?? '').toString();
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Data customer berhasil diambil dari Spreadsheet'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ambil data customer gagal: $e')),
      );
    } finally {
      if (mounted) setState(() => sedangAmbilCustomer = false);
    }
  }

  Future<void> updateSpreadsheet() async {
    final operational = operationalNumberController.text.trim();
    final endpoint = _linkSaSpreadsheetAktif.text.trim();
    final namaSa = _namaSaSpreadsheetAktif.text.trim();

    if (operational.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Operational Number belum diisi')),
      );
      return;
    }
    if (endpoint.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Link update Spreadsheet SA belum diisi')),
      );
      return;
    }

    final data = <Map<String, dynamic>>[
      ...daftarSparePart.map((e) => {
            'operationalNumber': operational,
            'kode': e.kode,
            'nama': e.nama,
            'quantity': e.qty,
          }),
      ...daftarBahan.map((e) => {
            'operationalNumber': operational,
            'kode': e.kode,
            'nama': e.nama,
            'quantity': e.qty,
          }),
    ];

    if (data.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Belum ada Spare Part atau Bahan untuk dikirim')),
      );
      return;
    }

    setState(() => sedangUpdateSpreadsheet = true);
    try {
      // Link yang digunakan di sini adalah URL Web App Google Apps Script.
      // Web App tersebut bertugas menghapus data lama lalu menulis data baru.
      // Google Apps Script Web App tidak mengirim header CORS pada responsnya.
      // Karena itu untuk Flutter Web kita gunakan simple POST (text/plain) agar
      // browser tidak melakukan CORS preflight. Request tetap diproses Apps Script.
      // Struktur JSON di bawah disamakan dengan doPost Apps Script: items + qty.
      final payload = jsonEncode({
        'operationalNumber': operational,
        'items': data
            .map((e) => {
                  'kode': e['kode'],
                  'nama': e['nama'],
                  'qty': e['quantity'],
                })
            .toList(),
      });

      try {
        final response = await http.post(
          Uri.parse(endpoint),
          headers: {'Content-Type': 'text/plain;charset=utf-8'},
          body: payload,
        );

        // Google Apps Script ContentService normalnya membalas POST dengan
        // redirect HTTP 302 menuju script.googleusercontent.com. Pada Android,
        // package:http dapat mengembalikan status 302 tersebut secara langsung.
        // POST sudah diterima/diproses Apps Script, jadi 302 dianggap sukses.
        final status = response.statusCode;
        final berhasil = (status >= 200 && status < 300) || status == 302;
        if (!berhasil) {
          throw Exception('HTTP $status: ${response.body}');
        }
      } on http.ClientException catch (e) {
        // Pada Flutter Web, Apps Script dapat sudah menerima dan memproses POST,
        // tetapi browser menolak membaca respons redirect karena CORS.
        // "Failed to fetch" pada tahap respons ini tidak berarti POST tidak terkirim.
        final pesan = e.message.toLowerCase();
        if (!pesan.contains('failed to fetch')) rethrow;
      }

      await simpanPengaturanSpreadsheet();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Update Spreadsheet $namaSa telah dikirim (${data.length} baris). Cek spreadsheet untuk memastikan data terbaru sudah masuk.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Update Spreadsheet gagal: $e')),
      );
    } finally {
      if (mounted) setState(() => sedangUpdateSpreadsheet = false);
    }
  }

  // ============================================================
  // DATABASE EXCEL
  // ============================================================

  Future<void> loadExcel() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final tersimpan = prefs.getString(_kunciDatabaseExcel);
      final namaFile = prefs.getString(_kunciNamaDatabaseExcel);

      Uint8List bytes;
      String sumber;
      if (tersimpan != null && tersimpan.isNotEmpty) {
        bytes = Uint8List.fromList(base64Decode(tersimpan));
        sumber = namaFile ?? 'Database import';
      } else {
        final data = await rootBundle.load('assets/project_estimasi.xlsx');
        bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        sumber = 'Database bawaan';
      }

      _terapkanExcelBytes(bytes);
      if (!mounted) return;
      setState(() {
        loadingExcel = false;
        statusExcel = '$sumber • ${spareParts.length} Spare Part • ${bahan.length} Bahan';
      });
    } catch (e) {
      debugPrint('ERROR EXCEL: $e');
      if (!mounted) return;
      setState(() {
        loadingExcel = false;
        statusExcel = 'Gagal membaca database Excel';
      });
    }
  }

  void _terapkanExcelBytes(Uint8List bytes) {
    final excel = Excel.decodeBytes(bytes);
    if (cariSheet(excel, 'SPARE PART') == null || cariSheet(excel, 'BAHAN') == null) {
      throw const FormatException('Sheet SPARE PART dan BAHAN wajib tersedia');
    }
    spareParts.clear();
    bahan.clear();
    bacaSparePart(excel);
    bacaBahan(excel);
    if (spareParts.isEmpty || bahan.isEmpty) {
      throw const FormatException('Data SPARE PART atau BAHAN kosong/tidak sesuai format');
    }
  }

  Future<void> importDatabaseExcel() async {
    try {
      final hasil = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        withData: true,
      );
      if (hasil == null || hasil.files.isEmpty) return;
      final file = hasil.files.single;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw const FormatException('File tidak dapat dibaca');
      }

      // Validasi memakai list sementara agar database aktif tidak berubah jika file salah.
      final excel = Excel.decodeBytes(bytes);
      final sp = cariSheet(excel, 'SPARE PART');
      final bh = cariSheet(excel, 'BAHAN');
      if (sp == null || bh == null) {
        throw const FormatException('Sheet SPARE PART dan BAHAN wajib tersedia');
      }
      int jumlahSp = 0;
      for (int i = 1; i < sp.maxRows; i++) {
        final row = sp.row(i);
        if (cellText(row, 1).isNotEmpty || cellText(row, 2).isNotEmpty) jumlahSp++;
      }
      int jumlahBh = 0;
      for (int i = 1; i < bh.maxRows; i++) {
        final row = bh.row(i);
        if (cellText(row, 0).isNotEmpty || cellText(row, 1).isNotEmpty) jumlahBh++;
      }
      if (jumlahSp == 0 || jumlahBh == 0) {
        throw const FormatException('Data SPARE PART atau BAHAN kosong/tidak sesuai format');
      }

      if (!mounted) return;
      final setuju = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Ganti Database Excel?'),
          content: Text(
            'File: ${file.name}\n\n'
            '$jumlahSp Spare Part • $jumlahBh Bahan\n\n'
            'Database Excel lama di aplikasi akan diganti. Estimasi favorit tetap tersimpan.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Batal')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Import & Ganti')),
          ],
        ),
      );
      if (setuju != true) return;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kunciDatabaseExcel, base64Encode(bytes));
      await prefs.setString(_kunciNamaDatabaseExcel, file.name);
      _terapkanExcelBytes(bytes);
      if (!mounted) return;
      setState(() {
        loadingExcel = false;
        statusExcel = '${file.name} • ${spareParts.length} Spare Part • ${bahan.length} Bahan';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Database Excel berhasil diganti')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import gagal: $e')),
      );
    }
  }

  Sheet? cariSheet(Excel excel, String target) {
    for (final nama in excel.tables.keys) {
      if (nama.trim().toUpperCase() ==
          target.trim().toUpperCase()) {
        return excel.tables[nama];
      }
    }

    return null;
  }

  void bacaSparePart(Excel excel) {
    final sheet = cariSheet(excel, 'SPARE PART');

    if (sheet == null) return;

    for (int i = 1; i < sheet.maxRows; i++) {
      final row = sheet.row(i);

      final tipeKendaraan = cellText(row, 0);
      final kode = cellText(row, 1);
      final nama = cellText(row, 2);
      final harga = cellHarga(row, 3);

      if (kode.isEmpty && nama.isEmpty) continue;

      spareParts.add(
        DatabaseItem(
          kode: kode,
          nama: nama,
          harga: harga,
          tipeKendaraan: tipeKendaraan,
        ),
      );
    }
  }

  void bacaBahan(Excel excel) {
    final sheet = cariSheet(excel, 'BAHAN');

    if (sheet == null) return;

    for (int i = 1; i < sheet.maxRows; i++) {
      final row = sheet.row(i);

      final kode = cellText(row, 0);
      final nama = cellText(row, 1);
      final harga = cellHarga(row, 2);

      if (kode.isEmpty && nama.isEmpty) continue;

      bahan.add(
        DatabaseItem(
          kode: kode,
          nama: nama,
          harga: harga,
        ),
      );
    }
  }

  String cellText(List<Data?> row, int index) {
    if (index >= row.length) return '';

    final value = row[index]?.value;

    if (value == null) return '';

    if (value is TextCellValue) {
      return value.value.toString().trim();
    }

    if (value is IntCellValue) {
      return value.value.toString();
    }

    if (value is DoubleCellValue) {
      return value.value.toString();
    }

    return value.toString().trim();
  }

  int cellHarga(List<Data?> row, int index) {
    if (index >= row.length) return 0;

    final value = row[index]?.value;

    if (value == null) return 0;

    if (value is IntCellValue) {
      return value.value;
    }

    if (value is DoubleCellValue) {
      return value.value.round();
    }

    String text;

    if (value is TextCellValue) {
      text = value.value.toString();
    } else {
      text = value.toString();
    }

    text = text.replaceAll(
      RegExp(r'[^0-9]'),
      '',
    );

    return int.tryParse(text) ?? 0;
  }

  // ============================================================
  // FILTER ITEM
  // ============================================================

  List<ItemEstimasi> get daftarJasa => itemEstimasi
      .where((e) => e.kategori == KategoriEstimasi.jasa)
      .toList();

  List<ItemEstimasi> get daftarSparePart => itemEstimasi
      .where((e) => e.kategori == KategoriEstimasi.sparePart)
      .toList();

  List<ItemEstimasi> get daftarBahan => itemEstimasi
      .where((e) => e.kategori == KategoriEstimasi.bahan)
      .toList();

  // ============================================================
  // TOTAL + DISKON
  // ============================================================

  double subtotalKategori(List<ItemEstimasi> items) =>
      items.fold(0.0, (total, item) => total + item.subtotal);

  double diskonKategori(List<ItemEstimasi> items) =>
      items.fold(0.0, (total, item) => total + item.nominalDiskon);

  double totalKategori(List<ItemEstimasi> items) =>
      items.fold(0.0, (total, item) => total + item.total);

  double get subtotalJasa => subtotalKategori(daftarJasa);
  double get diskonItemJasa => diskonKategori(daftarJasa);
  double get totalJasaSebelumDiskonAkhir => totalKategori(daftarJasa);
  double get diskonAkhirJasa =>
      totalJasaSebelumDiskonAkhir * diskonAkhirJasaPersen / 100;
  double get diskonJasa => diskonItemJasa + diskonAkhirJasa;
  double get totalJasa => totalJasaSebelumDiskonAkhir - diskonAkhirJasa;

  double get subtotalSparePart => subtotalKategori(daftarSparePart);
  double get diskonItemSparePart => diskonKategori(daftarSparePart);
  double get totalSparePartSebelumDiskonAkhir =>
      totalKategori(daftarSparePart);
  double get diskonAkhirSparePart =>
      totalSparePartSebelumDiskonAkhir * diskonAkhirSparePartPersen / 100;
  double get diskonSparePart =>
      diskonItemSparePart + diskonAkhirSparePart;
  double get totalSparePart =>
      totalSparePartSebelumDiskonAkhir - diskonAkhirSparePart;

  double get subtotalBahan => subtotalKategori(daftarBahan);
  double get diskonItemBahan => diskonKategori(daftarBahan);
  double get totalBahanSebelumDiskonAkhir => totalKategori(daftarBahan);
  double get diskonAkhirBahan =>
      totalBahanSebelumDiskonAkhir * diskonAkhirBahanPersen / 100;
  double get diskonBahan => diskonItemBahan + diskonAkhirBahan;
  double get totalBahan => totalBahanSebelumDiskonAkhir - diskonAkhirBahan;

  double get subtotalKeseluruhan =>
      subtotalJasa + subtotalSparePart + subtotalBahan;

  double get totalSebelumDiskonGrand =>
      totalJasa + totalSparePart + totalBahan;

  double get diskonGrand =>
      totalSebelumDiskonGrand * diskonGrandPersen / 100;

  double get totalDiskon =>
      diskonJasa + diskonSparePart + diskonBahan + diskonGrand;

  double get grandTotal => totalSebelumDiskonGrand - diskonGrand;

  // ============================================================
  // TAMBAH PART / BAHAN
  // ============================================================

  void tambahDatabaseItem(
    DatabaseItem databaseItem,
    KategoriEstimasi kategori,
  ) {
    final index = itemEstimasi.indexWhere(
      (item) =>
          item.kode == databaseItem.kode &&
          item.nama == databaseItem.nama &&
          item.kategori == kategori,
    );

    setState(() {
      if (index >= 0) {
        itemEstimasi[index].qty += 1;
      } else {
        itemEstimasi.add(
          ItemEstimasi(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            kode: databaseItem.kode,
            nama: databaseItem.nama,
            harga: databaseItem.harga,
            kategori: kategori,
            tipeKendaraan: databaseItem.tipeKendaraan,
            qty: 1,
          ),
        );
      }
    });
  }

  // ============================================================
  // JASA MANUAL
  // ============================================================

  void bukaJasaManual() {
    final namaController = TextEditingController();
    final hargaController = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Tambah Jasa'),
          content: SizedBox(
            width: MediaQuery.sizeOf(dialogContext).width < 600
                ? MediaQuery.sizeOf(dialogContext).width * 0.82
                : 450,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: namaController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Nama Jasa',
                    prefixIcon: Icon(Icons.build),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: hargaController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Harga Jasa',
                    prefixText: 'Rp ',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
              },
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () async {
                final nama = namaController.text.trim();

                final harga = int.tryParse(
                      hargaController.text.replaceAll(
                        RegExp(r'[^0-9]'),
                        '',
                      ),
                    ) ??
                    0;

                if (nama.isEmpty || harga <= 0) return;

                // Setiap jasa manual otomatis menjadi Master Jasa.
                // Duplikat dicegah berdasarkan nama jasa + tipe kendaraan.
                final tipe = tipeKendaraanController.text.trim();
                final indexMaster = jasaDatabase.indexWhere((e) =>
                    e.nama.trim().toLowerCase() == nama.toLowerCase() &&
                    e.tipeKendaraan.trim().toLowerCase() == tipe.toLowerCase());
                if (indexMaster >= 0) {
                  jasaDatabase[indexMaster].harga = harga;
                } else {
                  jasaDatabase.add(DatabaseItem(
                    kode: '',
                    nama: nama,
                    harga: harga,
                    tipeKendaraan: tipe,
                  ));
                }
                await simpanDatabaseManual();
                if (!mounted) return;

                setState(() {
                  itemEstimasi.add(
                    ItemEstimasi(
                      id: DateTime.now()
                          .microsecondsSinceEpoch
                          .toString(),
                      kode: '',
                      nama: nama,
                      harga: harga,
                      kategori: KategoriEstimasi.jasa,
                      qty: 1,
                    ),
                  );
                });

                Navigator.pop(dialogContext);
              },
              child: const Text('Tambahkan'),
            ),
          ],
        );
      },
    );
  }

  // ============================================================
  // PENCARIAN
  // ============================================================

  void bukaPencarian(
    String judul,
    List<DatabaseItem> source,
    KategoriEstimasi kategori,
  ) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        String keyword = '';

        return StatefulBuilder(
          builder: (context, setDialogState) {
            List<DatabaseItem> hasil = [];

            if (keyword.trim().isNotEmpty) {
              final query = keyword.trim().toLowerCase();

              hasil = source.where((item) {
                return item.kode.toLowerCase().contains(query) ||
                    item.nama.toLowerCase().contains(query) ||
                    item.tipeKendaraan.toLowerCase().contains(query);
              }).take(50).toList();
            }

            return Dialog(
              insetPadding: const EdgeInsets.all(16),
              child: SizedBox(
                width: MediaQuery.sizeOf(dialogContext).width < 720
                    ? MediaQuery.sizeOf(dialogContext).width - 32
                    : 680,
                height: MediaQuery.sizeOf(dialogContext).height < 700
                    ? MediaQuery.sizeOf(dialogContext).height * 0.78
                    : 650,
                child: Column(
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: const BoxDecoration(
                        color: biruUtama,
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(12),
                        ),
                      ),
                      child: Text(
                        judul,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: TextField(
                        autofocus: true,
                        decoration: InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          labelText: kategori == KategoriEstimasi.sparePart
                              ? 'Cari kode, nama part, atau tipe kendaraan'
                              : 'Cari kode atau nama',
                          hintText: kategori == KategoriEstimasi.sparePart
                              ? 'Contoh: OIL FILTER, D15601, atau M804'
                              : 'Ketik kode atau nama item',
                        ),
                        onChanged: (value) {
                          setDialogState(() {
                            keyword = value;
                          });
                        },
                      ),
                    ),
                    Expanded(
                      child: keyword.trim().isEmpty
                          ? const Center(
                              child: Text(
                                'Ketik kode atau nama untuk mencari',
                              ),
                            )
                          : hasil.isEmpty
                              ? const Center(
                                  child: Text('Data tidak ditemukan'),
                                )
                              : ListView.separated(
                                  itemCount: hasil.length,
                                  separatorBuilder: (_, __) =>
                                      const Divider(height: 1),
                                  itemBuilder: (context, index) {
                                    final item = hasil[index];

                                    return ListTile(
                                      leading: CircleAvatar(
                                        backgroundColor: biruMuda,
                                        child: Icon(
                                          kategori ==
                                                  KategoriEstimasi.sparePart
                                              ? Icons.settings
                                              : Icons.inventory_2,
                                          color: biruUtama,
                                        ),
                                      ),
                                      title: Text(
                                        item.nama,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      subtitle: kategori ==
                                              KategoriEstimasi.sparePart
                                          ? Text(
                                              item.tipeKendaraan.isEmpty
                                                  ? 'Kode: ${item.kode}'
                                                  : 'Kode: ${item.kode}\n'
                                                      'Tipe Kendaraan: ${item.tipeKendaraan}',
                                            )
                                          : Text(
                                              'Kode: ${item.kode}',
                                            ),
                                      trailing: Text(
                                        rupiah(item.harga.toDouble()),
                                        style: const TextStyle(
                                          color: biruUtama,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      onTap: () {
                                        tambahDatabaseItem(
                                          item,
                                          kategori,
                                        );

                                        Navigator.pop(dialogContext);
                                      },
                                    );
                                  },
                                ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ============================================================
  // EDIT SATUAN / QTY
  // ============================================================

  void editQty(ItemEstimasi item) {
    final controller = TextEditingController(
      text: formatQty(item.qty),
    );

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Ubah Satuan / Qty'),
          content: SizedBox(
            width: 350,
            child: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(
                  RegExp(r'[0-9,.]'),
                ),
              ],
              decoration: const InputDecoration(
                labelText: 'Satuan / Qty',
                hintText: 'Contoh: 0,75',
                prefixIcon: Icon(Icons.numbers),
              ),
              onSubmitted: (_) {
                simpanQty(
                  dialogContext,
                  item,
                  controller.text,
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
              },
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () {
                simpanQty(
                  dialogContext,
                  item,
                  controller.text,
                );
              },
              child: const Text('Simpan'),
            ),
          ],
        );
      },
    );
  }

  void simpanQty(
    BuildContext dialogContext,
    ItemEstimasi item,
    String input,
  ) {
    final text = input
        .trim()
        .replaceAll(',', '.');

    final qtyBaru = double.tryParse(text);

    if (qtyBaru == null || qtyBaru <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Qty harus lebih besar dari 0',
          ),
        ),
      );
      return;
    }

    setState(() {
      item.qty = qtyBaru;
    });

    Navigator.pop(dialogContext);
  }

  // ============================================================
  // EDIT DISKON
  // ============================================================

  void editDiskon(ItemEstimasi item) {
    final controller = TextEditingController(
      text: formatQty(item.diskonPersen),
    );

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Ubah Diskon'),
          content: SizedBox(
            width: 350,
            child: TextField(
              controller: controller,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9,.]')),
              ],
              decoration: const InputDecoration(
                labelText: 'Diskon (%)',
                hintText: 'Contoh: 10 atau 7,5',
                prefixIcon: Icon(Icons.percent),
              ),
              onSubmitted: (_) =>
                  simpanDiskon(dialogContext, item, controller.text),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () =>
                  simpanDiskon(dialogContext, item, controller.text),
              child: const Text('Simpan'),
            ),
          ],
        );
      },
    );
  }

  void simpanDiskon(
    BuildContext dialogContext,
    ItemEstimasi item,
    String input,
  ) {
    final diskonBaru =
        double.tryParse(input.trim().replaceAll(',', '.'));

    if (diskonBaru == null || diskonBaru < 0 || diskonBaru > 100) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Diskon harus antara 0 sampai 100%'),
        ),
      );
      return;
    }

    setState(() => item.diskonPersen = diskonBaru);
    Navigator.pop(dialogContext);
  }

  void editDiskonAkhir({
    required String judul,
    required double nilaiAwal,
    required ValueChanged<double> onSimpan,
  }) {
    final controller = TextEditingController(text: formatQty(nilaiAwal));

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(judul),
        content: SizedBox(
          width: 350,
          child: TextField(
            controller: controller,
            autofocus: true,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9,.]')),
            ],
            decoration: const InputDecoration(
              labelText: 'Diskon (%)',
              hintText: 'Contoh: 10 atau 7,5',
              prefixIcon: Icon(Icons.percent),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () {
              final value = double.tryParse(
                controller.text.trim().replaceAll(',', '.'),
              );
              if (value == null || value < 0 || value > 100) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Diskon harus antara 0 sampai 100%'),
                  ),
                );
                return;
              }
              setState(() => onSimpan(value));
              Navigator.pop(dialogContext);
            },
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // ESTIMASI FAVORIT - PENYIMPANAN LOKAL
  // ============================================================

  static const String _kunciDatabaseManual = 'database_manual_estimasi_v2';

  List<String> get daftarTipeKendaraan {
    final tipe = jasaDatabase.map((e) => e.tipeKendaraan.trim()).where((e) => e.isNotEmpty).toSet().toList();
    tipe.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return tipe;
  }

  Map<String, dynamic> _dbKeJson(DatabaseItem e) => {
    'kode': e.kode, 'nama': e.nama, 'harga': e.harga, 'tipe': e.tipeKendaraan,
  };

  DatabaseItem _dbDariJson(Map<String, dynamic> e) => DatabaseItem(
    kode: (e['kode'] ?? '').toString(), nama: (e['nama'] ?? '').toString(),
    harga: (e['harga'] as num?)?.toInt() ?? 0, tipeKendaraan: (e['tipe'] ?? '').toString(),
  );

  Future<void> loadDatabaseManual() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kunciDatabaseManual);
    if (raw == null || raw.isEmpty) return;
    try {
      final map = Map<String, dynamic>.from(jsonDecode(raw));
      setState(() {
        jasaDatabase..clear()..addAll(((map['jasa'] as List?) ?? []).whereType<Map>().map((e) => _dbDariJson(Map<String,dynamic>.from(e))));
        // Spare Part/Bahan sekarang disimpan di SQLite lokal,
        // jadi tidak didecode ke RAM saat cold start.
      });
    } catch (_) {}
  }

  Future<void> simpanDatabaseManual() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kunciDatabaseManual, jsonEncode({
      'jasa': jasaDatabase.map(_dbKeJson).toList(),
      'sparePart': const [],
      'bahan': const [],
    }));
  }

  Future<void> bukaEditDatabase([int awal = 0]) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        int tab = awal;
        String cari = '';
        var hasilMaster = <DatabaseItem>[];
        var loadingMaster = false;
        var serialMaster = 0;

        return StatefulBuilder(
          builder: (context, setD) {
            final isPhone = MediaQuery.sizeOf(context).width < 600;
            final sumber = tab == 0
                ? jasaDatabase
                : tab == 1
                    ? spareParts
                    : bahan;
            final hasil = tab == 0
                ? sumber.where((e) {
                    final q = cari.toLowerCase();
                    return q.isEmpty ||
                        e.nama.toLowerCase().contains(q) ||
                        e.kode.toLowerCase().contains(q) ||
                        e.tipeKendaraan.toLowerCase().contains(q);
                  }).toList()
                : hasilMaster;

            Widget itemDatabase(DatabaseItem e) {
              final info = [
                if (e.tipeKendaraan.isNotEmpty)
                  e.tipeKendaraan
                else if (tab == 0)
                  'Semua tipe',
                if (e.kode.isNotEmpty) e.kode,
              ].join(' • ');

              Future<void> edit() async {
                await _formDatabaseItem(tab, e);
                setD(() {});
              }

              Future<void> hapus() async {
                try {
                  if (tab == 1 || tab == 2) {
                    await _hapusItemMasterCloud(tab, e);
                  }
                  sumber.remove(e);
                  if (tab == 0) {
                    await simpanDatabaseManual();
                  } else {
                    await _simpanCacheMasterSaatIni();
                    unawaited(_sinkronMasterCloud());
                  }
                  setState(() {});
                  setD(() {});
                } catch (err) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Gagal menghapus data: $err')),
                  );
                }
              }

              if (isPhone) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        e.nama,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      if (info.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          info,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.grey.shade700),
                        ),
                      ],
                      const SizedBox(height: 7),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              rupiah(e.harga.toDouble()),
                              maxLines: 1,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                color: biruUtama,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Edit',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: edit,
                          ),
                          IconButton(
                            tooltip: 'Hapus',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.delete_outline, color: Colors.red),
                            onPressed: hapus,
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              }

              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  e.nama,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: info.isEmpty ? null : Text(info),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(rupiah(e.harga.toDouble())),
                    IconButton(icon: const Icon(Icons.edit_outlined), onPressed: edit),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: hapus,
                    ),
                  ],
                ),
              );
            }

            return AlertDialog(
              insetPadding: EdgeInsets.symmetric(
                horizontal: isPhone ? 18 : 40,
                vertical: isPhone ? 22 : 24,
              ),
              title: const Text('Edit Database'),
              content: SizedBox(
                width: isPhone ? MediaQuery.sizeOf(context).width * 0.90 : 700,
                height: isPhone ? MediaQuery.sizeOf(context).height * 0.72 : 560,
                child: Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: SegmentedButton<int>(
                        segments: [
                          const ButtonSegment(value: 0, label: Text('Jasa', maxLines: 1)),
                          ButtonSegment(
                            value: 1,
                            label: Text(
                              'Spare Part',
                              maxLines: 1,
                              softWrap: false,
                              style: TextStyle(fontSize: isPhone ? 12 : 14),
                            ),
                          ),
                          const ButtonSegment(value: 2, label: Text('Bahan', maxLines: 1)),
                        ],
                        selected: {tab},
                        showSelectedIcon: !isPhone,
                        onSelectionChanged: (v) => setD(() {
                          tab = v.first;
                          cari = '';
                          hasilMaster = [];
                          loadingMaster = false;
                          serialMaster++;
                        }),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        labelText: 'Cari database',
                      ),
                      onChanged: (v) async {
                        final q = v.trim();
                        final mySerial = ++serialMaster;
                        setD(() {
                          cari = v;
                          if (tab != 0) loadingMaster = q.isNotEmpty;
                          if (tab != 0 && q.isEmpty) hasilMaster = [];
                        });
                        if (tab == 0 || q.isEmpty) return;
                        final kategori = tab == 1
                            ? KategoriEstimasi.sparePart
                            : KategoriEstimasi.bahan;
                        final data = await _cariMasterLokal(kategori, q);
                        if (!dialogContext.mounted || mySerial != serialMaster) return;
                        setD(() {
                          hasilMaster = data;
                          loadingMaster = false;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        onPressed: () async {
                          await _formDatabaseItem(tab, null);
                          setD(() {});
                        },
                        icon: const Icon(Icons.add),
                        label: Text(tab == 0 ? 'Tambah Jasa' : 'Tambah Item'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: loadingMaster
                          ? const Center(child: CircularProgressIndicator())
                          : (tab != 0 && cari.trim().isEmpty)
                              ? const Center(
                                  child: Text(
                                    'Ketik nama atau kode untuk mencari database.',
                                    textAlign: TextAlign.center,
                                  ),
                                )
                              : hasil.isEmpty
                                  ? const Center(child: Text('Data tidak ditemukan'))
                                  : ListView.separated(
                                      itemCount: hasil.length,
                                      separatorBuilder: (_, __) => const Divider(height: 1),
                                      itemBuilder: (_, i) => itemDatabase(hasil[i]),
                                    ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Tutup'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _formDatabaseItem(int tab, DatabaseItem? item) async {
    final tipe = TextEditingController(text: item?.tipeKendaraan ?? '');
    final kode = TextEditingController(text: item?.kode ?? '');
    final nama = TextEditingController(text: item?.nama ?? '');
    final harga = TextEditingController(text: item == null ? '' : item.harga.toString());

    await showDialog<void>(
      context: context,
      builder: (dc) => AlertDialog(
        title: Text(item == null ? (tab == 0 ? 'Tambah Jasa' : 'Tambah Item') : 'Edit Item'),
        content: SizedBox(
          width: MediaQuery.sizeOf(context).width < 600
              ? MediaQuery.sizeOf(context).width * 0.82
              : 430,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (tab != 2)
                  TextField(
                    controller: tipe,
                    decoration: InputDecoration(
                      labelText: tab == 0
                          ? 'Tipe Kendaraan (kosong = semua tipe)'
                          : 'Tipe Kendaraan',
                    ),
                  ),
                if (tab != 2) const SizedBox(height: 10),
                if (tab != 0)
                  TextField(controller: kode, decoration: const InputDecoration(labelText: 'Kode')),
                if (tab != 0) const SizedBox(height: 10),
                TextField(
                  controller: nama,
                  decoration: InputDecoration(labelText: tab == 0 ? 'Nama Jasa' : 'Nama Item'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: harga,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Harga', prefixText: 'Rp '),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dc), child: const Text('Batal')),
          FilledButton(
            onPressed: () async {
              final h = int.tryParse(harga.text.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
              if (nama.text.trim().isEmpty || h <= 0) return;
              if (tab != 0 && kode.text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Kode item wajib diisi')),
                );
                return;
              }

              final sumber = tab == 0 ? jasaDatabase : tab == 1 ? spareParts : bahan;
              final baru = DatabaseItem(
                kode: kode.text.trim(),
                nama: nama.text.trim(),
                harga: h,
                tipeKendaraan: tipe.text.trim(),
              );

              try {
                if (tab == 1 || tab == 2) {
                  await _simpanItemMasterCloud(tab, item, baru);
                }
                if (!mounted) return;
                setState(() {
                  if (item == null) {
                    sumber.add(baru);
                  } else {
                    item.kode = baru.kode;
                    item.nama = baru.nama;
                    item.harga = baru.harga;
                    item.tipeKendaraan = baru.tipeKendaraan;
                  }
                });
                if (tab == 0) {
                  await simpanDatabaseManual();
                } else {
                  await _simpanCacheMasterSaatIni();
                  unawaited(_sinkronMasterCloud());
                }
                if (dc.mounted) Navigator.pop(dc);
              } catch (err) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Gagal menyimpan data: $err')),
                );
              }
            },
            child: const Text('Simpan'),
          ),
        ],
      ),
    );
  }

  void bukaPencarianJasa() {
    final tipe = tipeKendaraanController.text.trim();
    if (tipe.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Pilih Tipe Kendaraan pada Data Customer terlebih dahulu'))); return; }
    final hasil = jasaDatabase.where((e) => e.tipeKendaraan.trim().isEmpty || e.tipeKendaraan.trim().toLowerCase() == tipe.toLowerCase()).toList();
    bukaPencarian('Cari Jasa • $tipe', hasil, KategoriEstimasi.jasa);
  }

  static const String _kunciFavorit = 'estimasi_favorit_v1';
  static const String _kunciDatabaseExcel = 'database_excel_import_v1';
  static const String _kunciNamaDatabaseExcel = 'database_excel_nama_v1';

  Future<List<Map<String, dynamic>>> _bacaFavorit() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kunciFavorit);
    if (raw == null || raw.trim().isEmpty) return [];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _tulisFavorit(List<Map<String, dynamic>> data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kunciFavorit, jsonEncode(data));
  }

  Map<String, dynamic> _itemKeJson(ItemEstimasi item) {
    return {
      'kode': item.kode,
      'nama': item.nama,
      'harga': item.harga,
      'kategori': item.kategori.name,
      'qty': item.qty,
      'diskonPersen': item.diskonPersen,
      'tipeKendaraan': item.tipeKendaraan,
    };
  }

  Future<void> simpanEstimasiFavorit() async {
    if (itemEstimasi.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Estimasi masih kosong')),
      );
      return;
    }

    final namaController = TextEditingController();

    final namaFavorit = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Simpan Estimasi Favorit'),
        content: TextField(
          controller: namaController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Nama paket favorit',
            hintText: 'Contoh: Service 10.000 KM Sigra',
            prefixIcon: Icon(Icons.star_outline),
          ),
          onSubmitted: (value) {
            final nama = value.trim();
            if (nama.isNotEmpty) Navigator.pop(dialogContext, nama);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Batal'),
          ),
          FilledButton.icon(
            onPressed: () {
              final nama = namaController.text.trim();
              if (nama.isEmpty) return;
              Navigator.pop(dialogContext, nama);
            },
            icon: const Icon(Icons.save_outlined),
            label: const Text('Simpan'),
          ),
        ],
      ),
    );

    if (namaFavorit == null || namaFavorit.trim().isEmpty) return;

    final favorit = await _bacaFavorit();
    final dataBaru = <String, dynamic>{
      'id': DateTime.now().microsecondsSinceEpoch.toString(),
      'nama': namaFavorit.trim(),
      'dibuat': DateTime.now().toIso8601String(),
      'customer': {
        'nama': namaCustomerController.text.trim(), 'noPolisi': noPolisiController.text.trim(),
        'noTelepon': noTeleponController.text.trim(), 'kilometer': kilometerController.text.trim(), 'tipeKendaraan': tipeKendaraanController.text.trim(),
        'noRangka': noRangkaController.text.trim(),
      },
      'diskonAkhirJasaPersen': diskonAkhirJasaPersen,
      'diskonAkhirSparePartPersen': diskonAkhirSparePartPersen,
      'diskonAkhirBahanPersen': diskonAkhirBahanPersen,
      'diskonGrandPersen': diskonGrandPersen,
      'items': itemEstimasi.map(_itemKeJson).toList(),
    };

    final indexNama = favorit.indexWhere(
      (e) => (e['nama'] ?? '').toString().toLowerCase() ==
          namaFavorit.trim().toLowerCase(),
    );

    if (!mounted) return;

    if (indexNama >= 0) {
      final ganti = await showDialog<bool>(  
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Nama favorit sudah ada'),
          content: Text(
            'Favorit "$namaFavorit" sudah tersimpan. Ganti dengan estimasi sekarang?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Ganti'),
            ),
          ],
        ),
      );
      if (ganti != true) return;
      dataBaru['id'] = favorit[indexNama]['id'];
      favorit[indexNama] = dataBaru;
    } else {
      favorit.add(dataBaru);
    }

    await _tulisFavorit(favorit);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Favorit "$namaFavorit" berhasil disimpan')),
    );
  }

  int _hargaTerbaru(String kode, String nama, KategoriEstimasi kategori, int hargaLama, [String tipe = '']) {
    if (kategori == KategoriEstimasi.jasa) {
      for (final data in jasaDatabase) {
        if (data.nama.toLowerCase() == nama.toLowerCase() && data.tipeKendaraan.toLowerCase() == tipe.toLowerCase()) return data.harga;
      }
      return hargaLama;
    }

    final sumber = kategori == KategoriEstimasi.sparePart ? spareParts : bahan;

    for (final data in sumber) {
      if (kode.isNotEmpty && data.kode == kode) return data.harga;
    }

    for (final data in sumber) {
      if (data.nama.toLowerCase() == nama.toLowerCase()) return data.harga;
    }

    return hargaLama;
  }

  void _terapkanFavorit(Map<String, dynamic> favorit) {
    final rawItems = favorit['items'];
    if (rawItems is! List) return;

    final hasil = <ItemEstimasi>[];

    for (final raw in rawItems) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);

      final kategoriNama = (map['kategori'] ?? '').toString();
      KategoriEstimasi? kategori;
      for (final k in KategoriEstimasi.values) {
        if (k.name == kategoriNama) {
          kategori = k;
          break;
        }
      }
      if (kategori == null) continue;

      final kode = (map['kode'] ?? '').toString();
      final nama = (map['nama'] ?? '').toString();
      final hargaLama = (map['harga'] as num?)?.toInt() ?? 0;
      final qty = (map['qty'] as num?)?.toDouble() ?? 1;
      final diskon = (map['diskonPersen'] as num?)?.toDouble() ?? 0;
      final tipeItem = (map['tipeKendaraan'] ?? '').toString();

      hasil.add(
        ItemEstimasi(
          id: '${DateTime.now().microsecondsSinceEpoch}_${hasil.length}',
          kode: kode,
          nama: nama,
          harga: _hargaTerbaru(kode, nama, kategori, hargaLama, tipeItem),
          kategori: kategori,
          tipeKendaraan: tipeItem,
          qty: qty,
          diskonPersen: diskon,
        ),
      );
    }

    final customer = favorit['customer'] is Map ? Map<String,dynamic>.from(favorit['customer']) : <String,dynamic>{};
    setState(() {
      namaCustomerController.text = (customer['nama'] ?? '').toString();
      noPolisiController.text = (customer['noPolisi'] ?? '').toString();
      noTeleponController.text = (customer['noTelepon'] ?? '').toString();
      kilometerController.text = (customer['kilometer'] ?? '').toString();
      tipeKendaraanController.text = (customer['tipeKendaraan'] ?? '').toString();
      noRangkaController.text = (customer['noRangka'] ?? '').toString();
      itemEstimasi
        ..clear()
        ..addAll(hasil);
      diskonAkhirJasaPersen =
          (favorit['diskonAkhirJasaPersen'] as num?)?.toDouble() ?? 0;
      diskonAkhirSparePartPersen =
          (favorit['diskonAkhirSparePartPersen'] as num?)?.toDouble() ?? 0;
      diskonAkhirBahanPersen =
          (favorit['diskonAkhirBahanPersen'] as num?)?.toDouble() ?? 0;
      diskonGrandPersen =
          (favorit['diskonGrandPersen'] as num?)?.toDouble() ?? 0;
    });
  }

  Future<void> bukaEstimasiFavorit() async {
    var favorit = await _bacaFavorit();
    if (!mounted) return;

    if (favorit.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Belum ada estimasi favorit')),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.star, color: Colors.amber),
                SizedBox(width: 8),
                Text('Estimasi Favorit'),
              ],
            ),
            content: SizedBox(
              width: 620,
              height: 460,
              child: favorit.isEmpty
                  ? const Center(child: Text('Belum ada estimasi favorit'))
                  : ListView.separated(
                      itemCount: favorit.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final data = favorit[index];
                        final items = data['items'] is List
                            ? data['items'] as List
                            : const [];
                        return ListTile(
                          leading: const CircleAvatar(
                            backgroundColor: biruMuda,
                            child: Icon(Icons.star_outline, color: biruUtama),
                          ),
                          title: Text(
                            (data['nama'] ?? 'Tanpa nama').toString(),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text('${items.length} item'),
                          onTap: () {
                            _terapkanFavorit(data);
                            Navigator.pop(dialogContext);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Favorit "${data['nama']}" dimuat • harga part/bahan memakai database aktif',
                                ),
                              ),
                            );
                          },
                          trailing: IconButton(
                            tooltip: 'Hapus favorit',
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.red,
                            ),
                            onPressed: () async {
                              final hapus = await showDialog<bool>(
                                context: dialogContext,
                                builder: (confirmContext) => AlertDialog(
                                  title: const Text('Hapus Favorit?'),
                                  content: Text(
                                    'Hapus "${data['nama']}" dari favorit?',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(confirmContext, false),
                                      child: const Text('Batal'),
                                    ),
                                    FilledButton(
                                      onPressed: () =>
                                          Navigator.pop(confirmContext, true),
                                      child: const Text('Hapus'),
                                    ),
                                  ],
                                ),
                              );

                              if (hapus != true) return;
                              favorit.removeAt(index);
                              await _tulisFavorit(favorit);
                              setDialogState(() {});
                            },
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Tutup'),
              ),
            ],
          ),
        );
      },
    );
  }

  // ============================================================
  // PDF ESTIMASI
  // ============================================================

  String _formatIdrPdf(double value) {
    final angka = value.round().toString();
    final buffer = StringBuffer();
    for (int i = 0; i < angka.length; i++) {
      final posisi = angka.length - i;
      buffer.write(angka[i]);
      if (posisi > 1 && posisi % 3 == 1) buffer.write(',');
    }
    return 'IDR ${buffer.toString()}';
  }

  String _tanggalIndonesia(DateTime date) {
    const bulan = [
      'Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni',
      'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember'
    ];
    return '${date.day} ${bulan[date.month - 1]} ${date.year}';
  }

  String _namaFilePdf() {
    final nopol = noPolisiController.text.trim().isEmpty
        ? 'TANPA_NOPOL'
        : noPolisiController.text.trim();
    final customer = namaCustomerController.text.trim().isEmpty
        ? 'CUSTOMER'
        : namaCustomerController.text.trim();
    final aman = '$nopol $customer'
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return '$aman.pdf';
  }

  pw.Widget _pdfInfoRow(String kiriLabel, String kiriValue,
      String kananLabel, String kananValue) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
      child: pw.Row(
        children: [
          pw.SizedBox(width: 85, child: pw.Text(kiriLabel, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8))),
          pw.Expanded(child: pw.Text(kiriValue, style: const pw.TextStyle(fontSize: 8))),
          pw.SizedBox(width: 78, child: pw.Text(kananLabel, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 8))),
          pw.SizedBox(width: 105, child: pw.Text(kananValue, style: const pw.TextStyle(fontSize: 8))),
        ],
      ),
    );
  }

  pw.Widget _pdfKategori({
    required String judul,
    required String uraianHeader,
    required List<ItemEstimasi> items,
    required double total,
    required double diskonAkhirPersen,
  }) {
    final rows = <pw.TableRow>[];
    rows.add(
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey300),
        children: [
          _pdfCell('No', bold: true, center: true),
          _pdfCell(uraianHeader, bold: true),
          _pdfCell('Qty', bold: true, center: true),
          _pdfCell('Harga', bold: true),
          _pdfCell('Total', bold: true),
        ],
      ),
    );

    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      rows.add(
        pw.TableRow(
          children: [
            _pdfCell('${i + 1}', center: true),
            _pdfCell(item.nama),
            _pdfCell(formatQty(item.qty), center: true),
            _pdfCell(_formatIdrPdf(item.harga.toDouble())),
            _pdfCell(_formatIdrPdf(item.total)),
          ],
        ),
      );
      if (tampilkanDiskon && item.diskonPersen > 0) {
        rows.add(
          pw.TableRow(
            children: [
              _pdfCell(''),
              _pdfCell('Diskon item ${formatQty(item.diskonPersen)}%', italic: true),
              _pdfCell(''),
              _pdfCell(''),
              _pdfCell('-${_formatIdrPdf(item.nominalDiskon)}', italic: true),
            ],
          ),
        );
      }
    }

    if (items.isEmpty) {
      rows.add(pw.TableRow(children: [
        _pdfCell('1', center: true), _pdfCell('-'), _pdfCell('-', center: true), _pdfCell('IDR -'), _pdfCell('IDR -')
      ]));
    }

    if (tampilkanDiskon && diskonAkhirPersen > 0) {
      rows.add(
        pw.TableRow(
          children: [
            _pdfCell(''),
            _pdfCell('Diskon Akhir ${formatQty(diskonAkhirPersen)}%', bold: true),
            _pdfCell(''),
            _pdfCell(''),
            _pdfCell(''),
          ],
        ),
      );
    }

    rows.add(
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey300),
        children: [
          _pdfCell('', bold: true),
          _pdfCell('Total $judul', bold: true),
          _pdfCell('', bold: true),
          _pdfCell('', bold: true),
          _pdfCell(_formatIdrPdf(total), bold: true),
        ],
      ),
    );

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Container(
          alignment: pw.Alignment.center,
          padding: const pw.EdgeInsets.symmetric(vertical: 3),
          decoration: pw.BoxDecoration(
            color: PdfColors.grey300,
            border: pw.Border.all(width: 0.6),
          ),
          child: pw.Text(judul, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9)),
        ),
        pw.Table(
          border: pw.TableBorder.all(width: 0.45),
          columnWidths: const {
            0: pw.FixedColumnWidth(25),
            1: pw.FlexColumnWidth(5.2),
            2: pw.FixedColumnWidth(36),
            3: pw.FlexColumnWidth(1.8),
            4: pw.FlexColumnWidth(1.8),
          },
          children: rows,
        ),
      ],
    );
  }

  pw.Widget _pdfCell(String text, {bool bold = false, bool center = false, bool italic = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 3, vertical: 2.2),
      child: pw.Text(
        text,
        textAlign: center ? pw.TextAlign.center : pw.TextAlign.left,
        style: pw.TextStyle(
          fontSize: 7.5,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          fontStyle: italic ? pw.FontStyle.italic : pw.FontStyle.normal,
        ),
      ),
    );
  }

  Future<void> buatPdfEstimasi() async {
    if (itemEstimasi.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tambahkan item estimasi terlebih dahulu')),
      );
      return;
    }

    try {
      final pdf = pw.Document();
      final sekarang = DateTime.now();

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(22, 20, 22, 20),
          build: (pdfContext) => [
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.symmetric(vertical: 3),
              decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.7)),
              child: pw.Text(
                'PT. ASTRA INTERNATIONAL Tbk, Jln. Veteran No. 57, RT.02 / RW.02, Ciseureuh, Purwakarta',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Container(
              width: double.infinity,
              alignment: pw.Alignment.center,
              child: pw.Text(
                'Estimasi Biaya Perawatan/Perbaikan',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
              ),
            ),
            pw.SizedBox(height: 12),
            pw.Text('Untuk kendaraan dengan data sebagai berikut :', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 7),
            _pdfInfoRow('STNK atas Nama', namaCustomerController.text.trim(), 'Nomor Polisi', noPolisiController.text.trim()),
            _pdfInfoRow('Cabang', 'PURWAKARTA', 'Tipe Kendaraan', tipeKendaraanController.text.trim()),
            _pdfInfoRow('KILOMETER', kilometerController.text.trim(), 'No. Rangka', noRangkaController.text.trim()),
            pw.SizedBox(height: 7),
            _pdfKategori(
              judul: 'Jasa',
              uraianHeader: 'Uraian Pekerjaan',
              items: daftarJasa,
              total: totalJasa,
              diskonAkhirPersen: diskonAkhirJasaPersen,
            ),
            pw.SizedBox(height: 6),
            _pdfKategori(
              judul: 'Suku Cadang',
              uraianHeader: 'Uraian Suku Cadang',
              items: daftarSparePart,
              total: totalSparePart,
              diskonAkhirPersen: diskonAkhirSparePartPersen,
            ),
            pw.SizedBox(height: 6),
            _pdfKategori(
              judul: 'Bahan',
              uraianHeader: 'Uraian Bahan',
              items: daftarBahan,
              total: totalBahan,
              diskonAkhirPersen: diskonAkhirBahanPersen,
            ),
            pw.SizedBox(height: 7),
            if (tampilkanDiskon && diskonGrandPersen > 0)
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 3),
                decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.5)),
                child: pw.Row(children: [
                  pw.Expanded(child: pw.Text('Diskon Grand Total (${formatQty(diskonGrandPersen)}%)', style: const pw.TextStyle(fontSize: 8))),
                  pw.Text('-${_formatIdrPdf(diskonGrand)}', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
                ]),
              ),
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
              decoration: pw.BoxDecoration(
                color: PdfColors.yellow,
                border: pw.Border.all(width: 0.7),
              ),
              child: pw.Row(children: [
                pw.Expanded(child: pw.Text('GRAND TOTAL', textAlign: pw.TextAlign.center, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
                pw.SizedBox(width: 145, child: pw.Text(_formatIdrPdf(grandTotal), textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
              ]),
            ),
            pw.SizedBox(height: 6),
            pw.Text('Keterangan :', style: const pw.TextStyle(fontSize: 8)),
            pw.SizedBox(height: 6),
            pw.Text('1. Apabila terdapat penambahan diluar estimasi maka akan diberitahukan terlebih dahulu', style: const pw.TextStyle(fontSize: 7.5)),
            pw.Text('2. Estimasi biaya ini bukan bukti pembayaran', style: const pw.TextStyle(fontSize: 7.5)),
            pw.Text('3. Harga sudah termasuk PPN', style: const pw.TextStyle(fontSize: 7.5)),
            pw.Text('4. Pembayaran dapat ditransfer ke Rek. ${namaRekeningController.text.trim()} - ${namaBankController.text.trim()} : ${nomorRekeningController.text.trim()}', style: const pw.TextStyle(fontSize: 7.5)),
            pw.SizedBox(height: 8),
            pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Text('Purwakarta, ${_tanggalIndonesia(sekarang)}', style: const pw.TextStyle(fontSize: 8)),
                  pw.SizedBox(height: 28),
                  pw.Text(namaServiceAdvisorController.text.trim(), style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
                  pw.Text('Telp/WA : ${noWaServiceAdvisorController.text.trim()}', style: const pw.TextStyle(fontSize: 8)),
                ],
              ),
            ),
          ],
        ),
      );

      final bytes = await pdf.save();
      await Printing.sharePdf(bytes: bytes, filename: _namaFilePdf());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal membuat PDF: $e')),
      );
    }
  }

  // ============================================================
  // NOTIFIKASI SA + SINKRON TEMUAN ECO CLOUD
  // ============================================================

  Future<void> _siapkanNotifikasiSa() async {
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      await messaging.setAutoInitEnabled(true);

      const channel = AndroidNotificationChannel(
        'eco_temuan_sa',
        'Temuan Service SA',
        description: 'Notifikasi temuan baru dari teknisi',
        importance: Importance.max,
        playSound: true,
      );
      await _localNotifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(channel);

      final token = await messaging.getToken();
      if (token == null || token.isEmpty) {
        throw Exception('FCM token kosong. Pastikan Google Play Services/Firebase aktif.');
      }

      await Supabase.instance.client.from('eco_devices').upsert({
        'role': 'sa',
        'sa_id': _saIdAktif,
        'fcm_token': token,
        'platform': 'android',
      }, onConflict: 'fcm_token');

      debugPrint('FCM SA BERHASIL: ${token.substring(0, token.length > 20 ? 20 : token.length)}...');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('FCM SA berhasil • Token SA tersimpan'),
            duration: Duration(seconds: 5),
          ),
        );
      }

      messaging.onTokenRefresh.listen((tokenBaru) async {
  try {
    await Supabase.instance.client.from('eco_devices').upsert({
      'role': 'sa',
      'sa_id': _saIdAktif,
      'fcm_token': tokenBaru,
      'platform': 'android',
    }, onConflict: 'fcm_token');

    debugPrint(
      'TOKEN SA DIPERBARUI • $_saIdAktif • '
      '${tokenBaru.substring(0, tokenBaru.length > 20 ? 20 : tokenBaru.length)}...',
    );
  } catch (e) {
    debugPrint('SIMPAN TOKEN SA ERROR: $e');
  }
});

      FirebaseMessaging.onMessage.listen((message) async {
        const details = NotificationDetails(
          android: AndroidNotificationDetails(
            'eco_temuan_sa',
            'Temuan Service SA',
            channelDescription: 'Notifikasi temuan baru dari teknisi',
            importance: Importance.max,
            priority: Priority.high,
            playSound: true,
          ),
        );
        await _localNotifications.show(
          id: message.hashCode,
          title: message.notification?.title ?? 'Temuan Service Baru',
          body: message.notification?.body ?? 'Ada temuan baru dari teknisi.',
          notificationDetails: details,
        );
        await _sinkronTemuanCloud();
      });
    } catch (e) {
      debugPrint('NOTIFIKASI SA ERROR: $e');
    }
  }

  void _dengarkanTemuanRealtime() {
    _ecoFindingsChannel = Supabase.instance.client
        .channel('estimasi-sa-eco-findings')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'eco_findings',
          callback: (payload) {
            final record = payload.newRecord;
            final orderId = (record['order_id'] ?? '').toString();
            final milikSaIni = ecoEstimasi.any(
              (order) => (order['id'] ?? '').toString() == orderId,
            );
            if (milikSaIni &&
                (record['harga_diisi_oleh'] ?? '').toString() == 'partman') {
              unawaited(
                _localNotifications.show(
                  id: DateTime.now().millisecondsSinceEpoch.remainder(100000),
                  title: 'Harga Temuan Diperbarui',
                  body:
                      'Partman memperbarui harga ${(record['nama_part'] ?? 'temuan').toString()}.',
                  notificationDetails: const NotificationDetails(
                    android: AndroidNotificationDetails(
                      'eco_temuan_sa',
                      'Temuan Service SA',
                      channelDescription: 'Notifikasi pembaruan estimasi ECO',
                      importance: Importance.max,
                      priority: Priority.high,
                      playSound: true,
                    ),
                  ),
                ),
              );
            }
            unawaited(_sinkronTemuanCloud());
          },
        )
        .subscribe();
  }

  Future<void> _sinkronTemuanCloud() async {
    if (ecoEstimasi.isEmpty) return;
    try {
      for (final order in ecoEstimasi) {
        final orderId = (order['id'] ?? '').toString();
        if (orderId.isEmpty) continue;
        final rows = await Supabase.instance.client
            .from('eco_findings')
            .select()
            .eq('order_id', orderId)
            .order('created_at', ascending: false);
        final temuan = (rows as List)
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();

        // Kompatibilitas dengan ECO Partman versi lama yang hanya menyimpan
        // harga_part/harga_jasa. Tampilan Estimasi membaca tiga daftar JSON,
        // sehingga nilai lama perlu diterjemahkan menjadi item estimasi.
        for (final finding in temuan) {
          final rawPart = finding['estimasi_sparepart'];
          final rawBahan = finding['estimasi_bahan'];
          final partKosong = rawPart is! List || rawPart.isEmpty;
          final bahanKosong = rawBahan is! List || rawBahan.isEmpty;
          final hargaPart = (finding['harga_part'] as num?)?.toDouble() ??
              double.tryParse((finding['harga_part'] ?? '0').toString()) ??
              0;
          final qty = (finding['quantity'] as num?)?.toDouble() ??
              double.tryParse((finding['quantity'] ?? '1').toString()) ??
              1;

          if (partKosong && bahanKosong && hargaPart > 0) {
            finding['estimasi_sparepart'] = [
              {
                'kode': (finding['kode_part'] ?? '').toString(),
                'nama': (finding['nama_part'] ?? 'Spare Part').toString(),
                'harga': hargaPart,
                'qty': qty,
                'diskon': 0,
              }
            ];
          }

          final rawJasa = finding['estimasi_jasa'];
          final hargaJasa = (finding['harga_jasa'] as num?)?.toDouble() ??
              double.tryParse((finding['harga_jasa'] ?? '0').toString()) ??
              0;
          if ((rawJasa is! List || rawJasa.isEmpty) && hargaJasa > 0) {
            finding['estimasi_jasa'] = [
              {
                'kode': '',
                'nama': 'Jasa ${(finding['nama_part'] ?? '').toString()}',
                'harga': hargaJasa,
                'qty': 1,
                'diskon': 0,
              }
            ];
          }
        }
        order['temuan'] = temuan;
        order['jumlahTemuan'] = temuan.length;
        order['status'] = temuan.isEmpty ? 'Menunggu Temuan Teknisi' : 'Ada Temuan Teknisi';
      }
      await _simpanEcoEstimasi();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('SINKRON TEMUAN CLOUD ERROR: $e');
    }
  }

  Future<void> _isiPartOlehSa(Map<String, dynamic> finding) async {
    DatabaseItem? partTerpilih;
    var hasilCari = <DatabaseItem>[];
    var loadingCari = false;
    var serialCari = 0;
    final cariC = TextEditingController(
      text: (finding['kode_part'] ?? finding['nama_part'] ?? '').toString(),
    );

    final hasil = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          title: const Text('Pilih Spare Part dari Master'),
          content: SizedBox(
            width: MediaQuery.sizeOf(context).width < 600
                ? MediaQuery.sizeOf(context).width * 0.88
                : 620,
            height: MediaQuery.sizeOf(context).height < 700 ? 470 : 560,
            child: Column(
              children: [
                TextField(
                  controller: cariC,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Cari nama atau kode part',
                    hintText: 'Contoh: OIL FILTER atau 15601...',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (value) async {
                    final mySerial = ++serialCari;
                    final q = value.trim();
                    if (q.isEmpty) {
                      setD(() {
                        hasilCari = [];
                        loadingCari = false;
                        partTerpilih = null;
                      });
                      return;
                    }
                    setD(() => loadingCari = true);
                    final data = await _cariMasterLokal(
                      KategoriEstimasi.sparePart,
                      q,
                    );
                    if (!dc.mounted || mySerial != serialCari) return;
                    setD(() {
                      hasilCari = data;
                      loadingCari = false;
                    });
                  },
                ),
                const SizedBox(height: 10),
                if (partTerpilih != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: biruMuda,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          partTerpilih!.nama,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        Text('Kode: ${partTerpilih!.kode}'),
                        if (partTerpilih!.tipeKendaraan.isNotEmpty)
                          Text('Tipe: ${partTerpilih!.tipeKendaraan}'),
                        Text('Harga: ${rupiah(partTerpilih!.harga.toDouble())}'),
                      ],
                    ),
                  ),
                Expanded(
                  child: loadingCari
                      ? const Center(child: CircularProgressIndicator())
                      : hasilCari.isEmpty
                          ? const Center(
                              child: Text(
                                'Ketik nama atau kode part untuk mencari master Spare Part.',
                                textAlign: TextAlign.center,
                              ),
                            )
                          : ListView.separated(
                              itemCount: hasilCari.length,
                              separatorBuilder: (_, __) => const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final item = hasilCari[i];
                                final dipilih = partTerpilih?.kode == item.kode &&
                                    partTerpilih?.tipeKendaraan == item.tipeKendaraan;
                                return ListTile(
                                  selected: dipilih,
                                  leading: Icon(
                                    dipilih
                                        ? Icons.check_circle
                                        : Icons.settings_outlined,
                                    color: dipilih ? biruUtama : null,
                                  ),
                                  title: Text(
                                    item.nama,
                                    style: const TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                  subtitle: Text(
                                    item.tipeKendaraan.isEmpty
                                        ? 'Kode: ${item.kode}'
                                        : 'Kode: ${item.kode} • Tipe: ${item.tipeKendaraan}',
                                  ),
                                  trailing: Text(rupiah(item.harga.toDouble())),
                                  onTap: () => setD(() => partTerpilih = item),
                                );
                              },
                            ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dc),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: partTerpilih == null
                  ? null
                  : () => Navigator.pop(dc, {
                        'kode_part': partTerpilih!.kode,
                        'nama_part': partTerpilih!.nama,
                        'harga_part': partTerpilih!.harga,
                      }),
              child: const Text('Pilih & Simpan'),
            ),
          ],
        ),
      ),
    );
    cariC.dispose();
    if (hasil == null) return;
    final id = finding['id'];
    if (id == null) return;
    try {
      await Supabase.instance.client.from('eco_findings').update({
        ...hasil,
        'harga_diisi_oleh': 'sa',
      }).eq('id', id);
      await _sinkronTemuanCloud();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Spare Part master berhasil dipilih oleh SA')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal menyimpan data part: $e')),
      );
    }
  }

  // ============================================================
  // ECO / TEMUAN SERVICE - TAHAP 1
  // ============================================================

  Future<void> _loadEcoEstimasi() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kunciEcoEstimasi);
    if (raw == null || raw.trim().isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        ecoEstimasi
          ..clear()
          ..addAll(decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)));
        if (mounted) setState(() {});
      }
    } catch (_) {}
  }

  Future<void> _simpanEcoEstimasi() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kunciEcoEstimasi, jsonEncode(ecoEstimasi));
  }

  Future<void> _tambahkanEstimasiKeEco() async {
    final nama = namaCustomerController.text.trim();
    final nopol = noPolisiController.text.trim();
    final noTelepon = noTeleponController.text.trim();
    final tipe = tipeKendaraanController.text.trim();
    final rangka = noRangkaController.text.trim();
    final sa = namaServiceAdvisorController.text.trim();

    if (nama.isEmpty || nopol.isEmpty || noTelepon.isEmpty || tipe.isEmpty || rangka.isEmpty || sa.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Lengkapi Nama Customer, Nomor Polisi, Nomor Telepon/WhatsApp, Tipe Kendaraan, Nomor Rangka, dan Nama SA terlebih dahulu',
          ),
        ),
      );
      return;
    }

    try {
      final inserted = await Supabase.instance.client
          .from('eco_orders')
          .insert({
            'nama_customer': nama,
            'no_polisi': nopol,
            'tipe_kendaraan': tipe,
            'no_rangka': rangka,
            'nama_sa': sa,
            'sa_id': _saIdAktif,
            'status': 'menunggu_temuan_teknisi',
          })
          .select()
          .single();

      final data = <String, dynamic>{
        'id': inserted['id']?.toString() ?? DateTime.now().microsecondsSinceEpoch.toString(),
        'namaCustomer': nama,
        'noPolisi': nopol,
        'noTelepon': noTelepon,
        'tipeKendaraan': tipe,
        'noRangka': rangka,
        'namaSa': sa,
        'saId': _saIdAktif,
        'dibuat': inserted['created_at']?.toString() ?? DateTime.now().toIso8601String(),
        'jumlahTemuan': 0,
        'status': 'Menunggu Temuan Teknisi',
        'temuan': <Map<String, dynamic>>[],
      };

      if (!mounted) return;
      setState(() {
        ecoEstimasi.insert(0, data);
        _tabAktif = 5;
      });
      await _simpanEcoEstimasi();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Estimasi berhasil dikirim ke ECO Cloud')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal mengirim estimasi ke ECO Cloud: $e')),
      );
    }
  }


  List<Map<String, dynamic>> _temuanList(Map<String, dynamic> finding, String key) {
    final raw = finding[key];
    if (raw is List) {
      return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    return <Map<String, dynamic>>[];
  }

  double _angkaTemuan(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse((v ?? '').toString().replaceAll(',', '.')) ?? 0;
  }

  double _totalItemTemuan(Map<String, dynamic> e) {
    final harga = _angkaTemuan(e['harga']);
    final qty = _angkaTemuan(e['qty']);
    final diskon = _angkaTemuan(e['diskon']);
    return harga * qty * (1 - diskon / 100);
  }

  double _totalKategoriTemuan(List<Map<String, dynamic>> items) =>
      items.fold(0.0, (a, b) => a + _totalItemTemuan(b));

  Future<DatabaseItem?> _pilihMasterTemuan(KategoriEstimasi kategori) async {
    var hasil = <DatabaseItem>[];
    var loading = false;
    var serial = 0;
    return showDialog<DatabaseItem>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          title: Text(kategori == KategoriEstimasi.jasa
              ? 'Cari Jasa'
              : kategori == KategoriEstimasi.sparePart
                  ? 'Cari Spare Part'
                  : 'Cari Bahan'),
          content: SizedBox(
            width: 620,
            height: 520,
            child: Column(
              children: [
                TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    labelText: 'Cari nama atau kode',
                  ),
                  onChanged: (value) async {
                    final my = ++serial;
                    final q = value.trim().toLowerCase();
                    if (q.isEmpty) {
                      setD(() { hasil = []; loading = false; });
                      return;
                    }
                    setD(() => loading = true);
                    List<DatabaseItem> data;
                    if (kategori == KategoriEstimasi.jasa) {
                      final tipe = tipeKendaraanController.text.trim().toLowerCase();
                      data = jasaDatabase.where((e) {
                        final cocok = e.kode.toLowerCase().contains(q) || e.nama.toLowerCase().contains(q);
                        final et = e.tipeKendaraan.trim().toLowerCase();
                        return cocok && (et.isEmpty || tipe.isEmpty || et == tipe);
                      }).take(50).toList();
                    } else {
                      data = await _cariMasterLokal(kategori, value);
                    }
                    if (!dc.mounted || my != serial) return;
                    setD(() { hasil = data; loading = false; });
                  },
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: loading
                      ? const Center(child: CircularProgressIndicator())
                      : ListView.separated(
                          itemCount: hasil.length,
                          separatorBuilder: (_, __) => const Divider(height: 1),
                          itemBuilder: (_, i) {
                            final e = hasil[i];
                            return ListTile(
                              title: Text(e.nama, style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: Text([
                                if (e.kode.isNotEmpty) 'Kode: ${e.kode}',
                                if (e.tipeKendaraan.isNotEmpty) 'Tipe: ${e.tipeKendaraan}',
                              ].join(' • ')),
                              trailing: Text(rupiah(e.harga.toDouble())),
                              onTap: () => Navigator.pop(dc, e),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(dc), child: const Text('Batal'))],
        ),
      ),
    );
  }

  Future<void> _editItemTemuan(
    List<Map<String, dynamic>> target,
    KategoriEstimasi kategori,
    StateSetter setD,
  ) async {
    final master = await _pilihMasterTemuan(kategori);
    if (master == null) return;
    final qtyC = TextEditingController(text: '1');
    final diskonC = TextEditingController(text: '0');
    final ok = await showDialog<bool>(
      context: context,
      builder: (dc) => AlertDialog(
        title: Text(master.nama),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Harga: ${rupiah(master.harga.toDouble())}'),
          const SizedBox(height: 12),
          TextField(
            controller: qtyC,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Quantity'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: diskonC,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Diskon (%)'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dc, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(dc, true), child: const Text('Tambah')),
        ],
      ),
    );
    if (ok != true) return;
    setD(() => target.add({
      'kode': master.kode,
      'nama': master.nama,
      'harga': master.harga,
      'qty': double.tryParse(qtyC.text.replaceAll(',', '.')) ?? 1,
      'diskon': double.tryParse(diskonC.text.replaceAll(',', '.')) ?? 0,
    }));
    qtyC.dispose();
    diskonC.dispose();
  }

  Widget _editorKategoriTemuan(
    String judul,
    IconData icon,
    List<Map<String, dynamic>> items,
    KategoriEstimasi kategori,
    bool tampilDiskon,
    StateSetter setD,
  ) {
    return Card(
      elevation: 0,
      color: Colors.grey.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(icon, color: biruUtama),
            const SizedBox(width: 8),
            Expanded(child: Text(judul, style: const TextStyle(fontWeight: FontWeight.bold))),
            IconButton(
              tooltip: 'Tambah $judul',
              onPressed: () => _editItemTemuan(items, kategori, setD),
              icon: const Icon(Icons.add_circle_outline, color: biruUtama),
            ),
          ]),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text('Belum ada item', style: TextStyle(color: Colors.grey)),
            )
          else
            ...List.generate(items.length, (i) {
              final e = items[i];
              final qty = _angkaTemuan(e['qty']);
              final diskon = _angkaTemuan(e['diskon']);
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text((e['nama'] ?? '-').toString()),
                subtitle: Text(
                  '${e['kode'] ?? ''}\nQty ${formatQty(qty)} × ${rupiah(_angkaTemuan(e['harga']))}'
                  '${tampilDiskon && diskon > 0 ? ' • Diskon ${formatQty(diskon)}%' : ''}',
                ),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(rupiah(_totalItemTemuan(e)), style: const TextStyle(fontWeight: FontWeight.w600)),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () => setD(() => items.removeAt(i)),
                  ),
                ]),
              );
            }),
          const Divider(),
          Align(
            alignment: Alignment.centerRight,
            child: Text('Total $judul: ${rupiah(_totalKategoriTemuan(items))}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ]),
      ),
    );
  }

  Future<void> _bukaEditorTemuan(Map<String, dynamic> order, Map<String, dynamic> finding) async {
    final jasa = _temuanList(finding, 'estimasi_jasa');
    final part = _temuanList(finding, 'estimasi_sparepart');
    final bahan = _temuanList(finding, 'estimasi_bahan');
    var tampilDiskonTemuan = finding['diskon_tampil'] == true;

    final simpan = await showDialog<bool>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (context, setD) {
          final grand = _totalKategoriTemuan(jasa) + _totalKategoriTemuan(part) + _totalKategoriTemuan(bahan);
          final foto = (finding['foto_url'] ?? finding['photo_url'] ?? finding['foto'] ?? '').toString();
          final ket = (finding['kondisi'] ?? finding['keterangan'] ?? finding['deskripsi'] ?? '-').toString();
          return AlertDialog(
            insetPadding: const EdgeInsets.all(12),
            title: Row(children: [
              const Expanded(child: Text('Estimasi Temuan')),
              IconButton(
                tooltip: tampilDiskonTemuan ? 'Sembunyikan diskon' : 'Tampilkan diskon',
                onPressed: () => setD(() => tampilDiskonTemuan = !tampilDiskonTemuan),
                icon: Icon(tampilDiskonTemuan ? Icons.visibility : Icons.visibility_off),
              ),
            ]),
            content: SizedBox(
              width: 760,
              height: MediaQuery.sizeOf(context).height * .78,
              child: ListView(children: [
                if (foto.isNotEmpty)
                  _fotoTemuanWidget(foto, height: 230),
                const SizedBox(height: 10),
                Text(ket, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                _editorKategoriTemuan('Jasa', Icons.build_outlined, jasa, KategoriEstimasi.jasa, tampilDiskonTemuan, setD),
                _editorKategoriTemuan('Spare Part', Icons.settings_outlined, part, KategoriEstimasi.sparePart, tampilDiskonTemuan, setD),
                _editorKategoriTemuan('Bahan', Icons.water_drop_outlined, bahan, KategoriEstimasi.bahan, tampilDiskonTemuan, setD),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: biruMuda, borderRadius: BorderRadius.circular(10)),
                  child: Row(children: [
                    const Expanded(child: Text('GRAND TOTAL TEMUAN', style: TextStyle(fontWeight: FontWeight.bold))),
                    Text(rupiah(grand), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  ]),
                ),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dc, false), child: const Text('Batal')),
              FilledButton.icon(
                onPressed: () => Navigator.pop(dc, true),
                icon: const Icon(Icons.save_outlined),
                label: const Text('Simpan'),
              ),
            ],
          );
        },
      ),
    );
    if (simpan != true) return;
    try {
      await Supabase.instance.client.from('eco_findings').update({
        'estimasi_jasa': jasa,
        'estimasi_sparepart': part,
        'estimasi_bahan': bahan,
        'diskon_tampil': tampilDiskonTemuan,
        'harga_diisi_oleh': 'sa',
      }).eq('id', finding['id']);
      await _sinkronTemuanCloud();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Estimasi temuan berhasil disimpan')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal menyimpan estimasi temuan: $e')));
    }
  }

  Future<String?> _urlFotoTemuan(String path) async {
    final value = path.trim();
    if (value.isEmpty || value == '-') return null;
    if (value.startsWith('http://') || value.startsWith('https://')) return value;
    try {
      return await Supabase.instance.client.storage
          .from('eco-findings')
          .createSignedUrl(value, 60 * 60);
    } catch (e) {
      debugPrint('SIGNED URL FOTO TEMUAN ERROR: $e');
      return null;
    }
  }

  Widget _fotoTemuanWidget(String path, {double height = 170}) {
    return FutureBuilder<String?>(
      future: _urlFotoTemuan(path),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return SizedBox(
            height: height,
            child: const Center(child: CircularProgressIndicator()),
          );
        }
        final url = snapshot.data;
        if (url == null || url.isEmpty) {
          return SizedBox(
            height: 80,
            child: Center(child: Text('Foto tidak dapat dimuat', style: TextStyle(color: Colors.grey.shade700))),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.network(
            url,
            height: height,
            width: double.infinity,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => SizedBox(
              height: 80,
              child: Center(child: Text('Foto tidak dapat dimuat', style: TextStyle(color: Colors.grey.shade700))),
            ),
          ),
        );
      },
    );
  }

  Future<Uint8List?> _ambilFotoTemuan(String path) async {
    final url = await _urlFotoTemuan(path);
    if (url == null) return null;
    try {
      final r = await http.get(Uri.parse(url));
      if (r.statusCode >= 200 && r.statusCode < 300) return r.bodyBytes;
    } catch (e) {
      debugPrint('DOWNLOAD FOTO TEMUAN ERROR: $e');
    }
    return null;
  }

  Future<void> _muatTemplateWaTemuan() async {
    final prefs = await SharedPreferences.getInstance();
    templateWaTemuanController.text =
        prefs.getString(_kTemplateWaTemuan) ?? _templateWaTemuanDefault;
  }

  Future<void> _simpanTemplateWaTemuan() async {
    final prefs = await SharedPreferences.getInstance();
    final value = templateWaTemuanController.text.trim();
    await prefs.setString(
      _kTemplateWaTemuan,
      value.isEmpty ? _templateWaTemuanDefault : value,
    );
    if (value.isEmpty) templateWaTemuanController.text = _templateWaTemuanDefault;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Template pesan WhatsApp tersimpan')),
    );
  }

  String _normalisasiNomorWa(String input) {
    var nomor = input.replaceAll(RegExp(r'[^0-9]'), '');
    if (nomor.startsWith('0')) nomor = '62${nomor.substring(1)}';
    if (nomor.startsWith('8')) nomor = '62$nomor';
    return nomor;
  }

  Future<void> _kirimPesanWaTemuan(
    Map<String, dynamic> order,
    List<Map<String, dynamic>> findings,
  ) async {
    if (findings.isEmpty) return;
    final nomor = _normalisasiNomorWa((order['noTelepon'] ?? '').toString());
    if (nomor.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nomor WhatsApp customer belum diisi')),
      );
      return;
    }

    double total = 0;
    for (final f in findings) {
      total += _totalKategoriTemuan(_temuanList(f, 'estimasi_jasa'));
      total += _totalKategoriTemuan(_temuanList(f, 'estimasi_sparepart'));
      total += _totalKategoriTemuan(_temuanList(f, 'estimasi_bahan'));
    }

    final pesanAwal = _pesanWaTemuan(order, findings, total);
    final pesan = await _editPesanWaSebelumKirim(pesanAwal);
    if (pesan == null || pesan.trim().isEmpty) return;

    final uri = Uri.parse(
      'https://wa.me/$nomor?text=${Uri.encodeComponent(pesan.trim())}',
    );
    final berhasil = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!berhasil && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('WhatsApp tidak dapat dibuka')),
      );
    }
  }

  Future<String?> _editPesanWaSebelumKirim(String pesanAwal) async {
    final controller = TextEditingController(text: pesanAwal);
    final hasil = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Preview Pesan WhatsApp'),
        content: SizedBox(
          width: 600,
          child: TextField(
            controller: controller,
            minLines: 12,
            maxLines: 20,
            decoration: const InputDecoration(
              labelText: 'Pesan yang akan dikirim',
              alignLabelWithHint: true,
              hintText: 'Pesan masih dapat diubah sebelum WhatsApp dibuka',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Batal'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            icon: const Icon(Icons.share),
            label: const Text('Buka WhatsApp'),
          ),
        ],
      ),
    );
    controller.dispose();
    return hasil;
  }

  String _pesanWaTemuan(
    Map<String, dynamic> order,
    List<Map<String, dynamic>> findings,
    double grandTotal,
  ) {
    final nama = (order['namaCustomer'] ?? '').toString().trim();
    final nopol = (order['noPolisi'] ?? '').toString().trim();
    final tipe = (order['tipeKendaraan'] ?? '').toString().trim();
    final sa = (order['namaSa'] ?? namaServiceAdvisorController.text).toString().trim();

    final detail = <String>[];
    for (var i = 0; i < findings.length; i++) {
      final f = findings[i];
      final kondisi = (f['kondisi'] ?? f['keterangan'] ?? f['deskripsi'] ?? '').toString().trim();
      if (kondisi.isNotEmpty && kondisi != '-') {
        detail.add('${i + 1}. $kondisi');
      }
    }

    var template = templateWaTemuanController.text.trim();
    if (template.isEmpty) template = _templateWaTemuanDefault;
    return template
        .replaceAll('{nama}', nama)
        .replaceAll('{nopol}', nopol)
        .replaceAll('{tipe}', tipe)
        .replaceAll('{temuan}', detail.isEmpty ? '-' : detail.join('\n'))
        .replaceAll('{total}', rupiah(grandTotal))
        .replaceAll('{sa}', sa);
  }

  Future<void> _buatPdfTemuan(Map<String, dynamic> order, List<Map<String, dynamic>> findings) async {
    if (findings.isEmpty) return;

    try {
      final pdf = pw.Document();
      final sekarang = DateTime.now();

      // Gabungkan estimasi hanya dari temuan yang dipilih.
      final jasaPdf = <ItemEstimasi>[];
      final partPdf = <ItemEstimasi>[];
      final bahanPdf = <ItemEstimasi>[];
      var tampilkanDiskonPdf = false;

      void tambahItem(
        List<Map<String, dynamic>> sumber,
        List<ItemEstimasi> tujuan,
        KategoriEstimasi kategori,
        String prefix,
      ) {
        for (var i = 0; i < sumber.length; i++) {
          final e = sumber[i];
          final item = ItemEstimasi(
            id: '${prefix}_${DateTime.now().microsecondsSinceEpoch}_$i',
            kode: (e['kode'] ?? e['kode_part'] ?? '').toString(),
            nama: (e['nama'] ?? e['nama_part'] ?? '-').toString(),
            harga: _angkaTemuan(e['harga']).round(),
            kategori: kategori,
            qty: _angkaTemuan(e['qty']),
            diskonPersen: _angkaTemuan(e['diskon']),
          );
          if (item.diskonPersen > 0) tampilkanDiskonPdf = true;
          tujuan.add(item);
        }
      }

      for (var fIndex = 0; fIndex < findings.length; fIndex++) {
        final f = findings[fIndex];
        if (f['diskon_tampil'] == true) tampilkanDiskonPdf = true;
        tambahItem(_temuanList(f, 'estimasi_jasa'), jasaPdf, KategoriEstimasi.jasa, 'j$fIndex');
        tambahItem(_temuanList(f, 'estimasi_sparepart'), partPdf, KategoriEstimasi.sparePart, 'p$fIndex');
        tambahItem(_temuanList(f, 'estimasi_bahan'), bahanPdf, KategoriEstimasi.bahan, 'b$fIndex');
      }

      double totalPdf(List<ItemEstimasi> items) =>
          items.fold<double>(0, (sum, item) => sum + item.total);

      final totalJasaPdf = totalPdf(jasaPdf);
      final totalPartPdf = totalPdf(partPdf);
      final totalBahanPdf = totalPdf(bahanPdf);
      final grandTotalPdf = totalJasaPdf + totalPartPdf + totalBahanPdf;

      // HALAMAN 1: desain sama dengan PDF Estimasi Service utama.
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(22, 20, 22, 20),
          build: (_) => [
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.symmetric(vertical: 3),
              decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.7)),
              child: pw.Text(
                'PT. ASTRA INTERNATIONAL Tbk, Jln. Veteran No. 57, RT.02 / RW.02, Ciseureuh, Purwakarta',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
              ),
            ),
            pw.SizedBox(height: 4),
            pw.Container(
              width: double.infinity,
              alignment: pw.Alignment.center,
              child: pw.Text(
                'Estimasi Biaya Perawatan/Perbaikan',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
              ),
            ),
            pw.SizedBox(height: 12),
            pw.Text('Untuk kendaraan dengan data sebagai berikut :',
                style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 7),
            _pdfInfoRow('STNK atas Nama', (order['namaCustomer'] ?? '').toString(),
                'Nomor Polisi', (order['noPolisi'] ?? '').toString()),
            _pdfInfoRow('Cabang', 'PURWAKARTA',
                'Tipe Kendaraan', (order['tipeKendaraan'] ?? '').toString()),
            _pdfInfoRow('KILOMETER', kilometerController.text.trim(),
                'No. Rangka', (order['noRangka'] ?? '').toString()),
            pw.SizedBox(height: 7),
            _pdfKategoriTemuan(
              judul: 'Jasa',
              uraianHeader: 'Uraian Pekerjaan',
              items: jasaPdf,
              total: totalJasaPdf,
              tampilkanDiskonPdf: tampilkanDiskonPdf,
            ),
            pw.SizedBox(height: 6),
            _pdfKategoriTemuan(
              judul: 'Suku Cadang',
              uraianHeader: 'Uraian Suku Cadang',
              items: partPdf,
              total: totalPartPdf,
              tampilkanDiskonPdf: tampilkanDiskonPdf,
            ),
            pw.SizedBox(height: 6),
            _pdfKategoriTemuan(
              judul: 'Bahan',
              uraianHeader: 'Uraian Bahan',
              items: bahanPdf,
              total: totalBahanPdf,
              tampilkanDiskonPdf: tampilkanDiskonPdf,
            ),
            pw.SizedBox(height: 7),
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
              decoration: pw.BoxDecoration(
                color: PdfColors.yellow,
                border: pw.Border.all(width: 0.7),
              ),
              child: pw.Row(children: [
                pw.Expanded(child: pw.Text('GRAND TOTAL', textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
                pw.SizedBox(width: 145, child: pw.Text(_formatIdrPdf(grandTotalPdf),
                    textAlign: pw.TextAlign.right,
                    style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
              ]),
            ),
            pw.SizedBox(height: 6),
            pw.Text('Keterangan :', style: const pw.TextStyle(fontSize: 8)),
            pw.SizedBox(height: 6),
            pw.Text('1. Apabila terdapat penambahan diluar estimasi maka akan diberitahukan terlebih dahulu', style: const pw.TextStyle(fontSize: 7.5)),
            pw.Text('2. Estimasi biaya ini bukan bukti pembayaran', style: const pw.TextStyle(fontSize: 7.5)),
            pw.Text('3. Harga sudah termasuk PPN', style: const pw.TextStyle(fontSize: 7.5)),
            pw.Text('4. Pembayaran dapat ditransfer ke Rek. ${namaRekeningController.text.trim()} - ${namaBankController.text.trim()} : ${nomorRekeningController.text.trim()}', style: const pw.TextStyle(fontSize: 7.5)),
            pw.SizedBox(height: 8),
            pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Text('Purwakarta, ${_tanggalIndonesia(sekarang)}', style: const pw.TextStyle(fontSize: 8)),
                  pw.SizedBox(height: 28),
                  pw.Text((order['namaSa'] ?? namaServiceAdvisorController.text).toString(),
                      style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
                  pw.Text('Telp/WA : ${noWaServiceAdvisorController.text.trim()}', style: const pw.TextStyle(fontSize: 8)),
                ],
              ),
            ),
          ],
        ),
      );

      // Ambil foto untuk lampiran temuan.
      final fotoBytes = <String, Uint8List?>{};
      for (final f in findings) {
        final u = (f['foto_url'] ?? f['photo_url'] ?? f['foto'] ?? '').toString();
        if (u.isNotEmpty && !fotoBytes.containsKey(u)) {
          fotoBytes[u] = await _ambilFotoTemuan(u);
        }
      }

      // HALAMAN 2 dst: foto kiri, nama komponen + kondisi di kanan.
      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(22, 20, 22, 20),
          header: (_) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Text('Lampiran Temuan Pemeriksaan',
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 3),
              pw.Text('${(order['namaCustomer'] ?? '').toString()} • ${(order['noPolisi'] ?? '').toString()}',
                  textAlign: pw.TextAlign.center,
                  style: const pw.TextStyle(fontSize: 8)),
              pw.SizedBox(height: 10),
            ],
          ),
          build: (_) => [
            for (var i = 0; i < findings.length; i++)
              _pdfKartuFotoTemuan(i + 1, findings[i], fotoBytes),
          ],
        ),
      );

      final bytes = await pdf.save();
      final nopol = (order['noPolisi'] ?? 'TEMUAN')
          .toString()
          .replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
      await Printing.sharePdf(bytes: bytes, filename: 'Estimasi_Temuan_$nopol.pdf');

      // Tandai order sebagai sudah direlease. Gagal update status tidak membatalkan PDF.
      final orderId = (order['id'] ?? '').toString();
      if (orderId.isNotEmpty) {
        try {
          await Supabase.instance.client
              .from('eco_orders')
              .update({'status': 'pdf_released'})
              .eq('id', orderId)
              .eq('sa_id', _saIdAktif);
        } catch (e) {
          debugPrint('UPDATE STATUS PDF RELEASE ERROR: $e');
        }
      }
      order['status'] = 'PDF Direlease';
      await _simpanEcoEstimasi();
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Gagal membuat PDF temuan: $e')),
      );
    }
  }

  pw.Widget _pdfKategoriTemuan({
    required String judul,
    required String uraianHeader,
    required List<ItemEstimasi> items,
    required double total,
    required bool tampilkanDiskonPdf,
  }) {
    final rows = <pw.TableRow>[
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.grey300),
        children: [
          _pdfCell('No', bold: true, center: true),
          _pdfCell(uraianHeader, bold: true),
          _pdfCell('Qty', bold: true, center: true),
          _pdfCell('Harga', bold: true),
          _pdfCell('Total', bold: true),
        ],
      ),
    ];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      rows.add(pw.TableRow(children: [
        _pdfCell('${i + 1}', center: true),
        _pdfCell(item.nama),
        _pdfCell(formatQty(item.qty), center: true),
        _pdfCell(_formatIdrPdf(item.harga.toDouble())),
        _pdfCell(_formatIdrPdf(item.total)),
      ]));
      if (tampilkanDiskonPdf && item.diskonPersen > 0) {
        rows.add(pw.TableRow(children: [
          _pdfCell(''),
          _pdfCell('Diskon item ${formatQty(item.diskonPersen)}%', italic: true),
          _pdfCell(''),
          _pdfCell(''),
          _pdfCell('-${_formatIdrPdf(item.nominalDiskon)}', italic: true),
        ]));
      }
    }
    if (items.isEmpty) {
      rows.add(pw.TableRow(children: [
        _pdfCell('1', center: true), _pdfCell('-'), _pdfCell('-', center: true),
        _pdfCell('IDR -'), _pdfCell('IDR -'),
      ]));
    }
    rows.add(pw.TableRow(
      decoration: const pw.BoxDecoration(color: PdfColors.grey300),
      children: [
        _pdfCell('', bold: true), _pdfCell('Total $judul', bold: true),
        _pdfCell('', bold: true), _pdfCell('', bold: true),
        _pdfCell(_formatIdrPdf(total), bold: true),
      ],
    ));
    return pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      pw.Container(
        alignment: pw.Alignment.center,
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        decoration: pw.BoxDecoration(color: PdfColors.grey300, border: pw.Border.all(width: 0.6)),
        child: pw.Text(judul, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 9)),
      ),
      pw.Table(
        border: pw.TableBorder.all(width: 0.45),
        columnWidths: const {
          0: pw.FixedColumnWidth(25), 1: pw.FlexColumnWidth(5.2),
          2: pw.FixedColumnWidth(36), 3: pw.FlexColumnWidth(1.8), 4: pw.FlexColumnWidth(1.8),
        },
        children: rows,
      ),
    ]);
  }

  pw.Widget _pdfKartuFotoTemuan(
    int nomor,
    Map<String, dynamic> finding,
    Map<String, Uint8List?> fotoBytes,
  ) {
    final path = (finding['foto_url'] ?? finding['photo_url'] ?? finding['foto'] ?? '').toString();
    final nama = (finding['nama_part'] ?? finding['namaPart'] ?? finding['part'] ?? 'Temuan $nomor').toString();
    final kondisi = (finding['kondisi'] ?? finding['keterangan'] ?? finding['deskripsi'] ?? '-').toString();
    final bytes = fotoBytes[path];

    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 10),
      padding: const pw.EdgeInsets.all(7),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(width: 0.6, color: PdfColors.grey600),
        borderRadius: pw.BorderRadius.circular(5),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Container(
            width: 165,
            height: 112,
            alignment: pw.Alignment.center,
            decoration: pw.BoxDecoration(
              color: PdfColors.grey200,
              border: pw.Border.all(width: 0.4, color: PdfColors.grey500),
            ),
            child: bytes != null
                ? pw.Image(pw.MemoryImage(bytes), fit: pw.BoxFit.contain)
                : pw.Text('Foto tidak tersedia', style: const pw.TextStyle(fontSize: 8)),
          ),
          pw.SizedBox(width: 12),
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('TEMUAN $nomor',
                    style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 8),
                pw.Text('Nama Part / Komponen',
                    style: pw.TextStyle(fontSize: 7, color: PdfColors.grey700)),
                pw.SizedBox(height: 2),
                pw.Text(nama,
                    style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 8),
                pw.Text('Keterangan Kerusakan',
                    style: pw.TextStyle(fontSize: 7, color: PdfColors.grey700)),
                pw.SizedBox(height: 2),
                pw.Text(kondisi, style: const pw.TextStyle(fontSize: 9)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pilihTemuanUntukPdf(Map<String, dynamic> order) async {
    final semua = ((order['temuan'] as List?) ?? const [])
        .whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    if (semua.isEmpty) return;
    final pilih = <int>{for (var i = 0; i < semua.length; i++) i};
    final ok = await showDialog<bool>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          title: const Text('Pilih Temuan yang Akan Dikirim'),
          content: SizedBox(
            width: 520,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: semua.length,
              itemBuilder: (_, i) => CheckboxListTile(
                value: pilih.contains(i),
                title: Text('Temuan ${i + 1}'),
                subtitle: Text((semua[i]['kondisi'] ?? semua[i]['keterangan'] ?? '-').toString()),
                onChanged: (v) => setD(() => v == true ? pilih.add(i) : pilih.remove(i)),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dc, false), child: const Text('Batal')),
            FilledButton(onPressed: pilih.isEmpty ? null : () => Navigator.pop(dc, true), child: const Text('Buat PDF')),
          ],
        ),
      ),
    );
    if (ok == true) {
      await _buatPdfTemuan(order, [for (final i in pilih.toList()..sort()) semua[i]]);
    }
  }

  bool _orderSudahDirelease(Map<String, dynamic> order) {
    final status = (order['status'] ?? '').toString().toLowerCase();
    return status == 'pdf direlease' ||
        status == 'pdf_released' ||
        status == 'released';
  }

  String? _storagePathFotoTemuan(dynamic raw) {
    final value = (raw ?? '').toString().trim();
    if (value.isEmpty || value == '-') return null;
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      return value.startsWith('/') ? value.substring(1) : value;
    }
    try {
      final uri = Uri.parse(value);
      final decoded = Uri.decodeComponent(uri.path);
      const markers = [
        '/storage/v1/object/sign/eco-findings/',
        '/storage/v1/object/public/eco-findings/',
        '/storage/v1/object/eco-findings/',
      ];
      for (final marker in markers) {
        final i = decoded.indexOf(marker);
        if (i >= 0) return decoded.substring(i + marker.length);
      }
    } catch (_) {}
    return null;
  }

  Future<void> _hapusHistoryTemuanTerpilih(
    List<Map<String, dynamic>> orders,
  ) async {
    if (orders.isEmpty) return;

    var berhasil = 0;
    final gagal = <String>[];

    for (final order in orders) {
      final orderId = (order['id'] ?? '').toString();
      final nopol = (order['noPolisi'] ?? '-').toString();
      if (orderId.isEmpty) continue;

      try {
        // Ambil ulang temuan agar path foto yang dihapus benar-benar data cloud terbaru.
        final rows = await Supabase.instance.client
            .from('eco_findings')
            .select('id,foto_url')
            .eq('order_id', orderId);

        final paths = <String>[];
        for (final raw in (rows as List)) {
          if (raw is! Map) continue;
          final path = _storagePathFotoTemuan(raw['foto_url']);
          if (path != null && path.isNotEmpty) paths.add(path);
        }

        // Foto dihapus lebih dulu agar tidak menjadi file yatim di Storage.
        if (paths.isNotEmpty) {
          await Supabase.instance.client.storage
              .from('eco-findings')
              .remove(paths.toSet().toList());
        }

        // Baru hapus temuan dan order. SA ID menjadi pengaman agar SA lain tidak terhapus.
        await Supabase.instance.client
            .from('eco_findings')
            .delete()
            .eq('order_id', orderId);

        await Supabase.instance.client
            .from('eco_orders')
            .delete()
            .eq('id', orderId)
            .eq('sa_id', _saIdAktif);

        ecoEstimasi.removeWhere((e) => (e['id'] ?? '').toString() == orderId);
        berhasil++;
      } catch (e) {
        debugPrint('CLEAR HISTORY $orderId ERROR: $e');
        gagal.add(nopol);
      }
    }

    await _simpanEcoEstimasi();
    if (!mounted) return;
    setState(() {});

    final pesan = gagal.isEmpty
        ? '$berhasil history selesai berhasil dihapus dari cloud.'
        : '$berhasil berhasil dihapus. Gagal: ${gagal.join(', ')}';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(pesan)));
  }

  Future<void> _clearHistoryTemuan() async {
    final history = ecoEstimasi
        .where(_orderSudahDirelease)
        .where((e) {
          final saId = (e['saId'] ?? e['sa_id'] ?? _saIdAktif).toString();
          return saId == _saIdAktif;
        })
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    if (history.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Belum ada history PDF yang sudah direlease untuk dibersihkan.'),
        ),
      );
      return;
    }

    final dipilih = <String>{};
    final konfirmasi = await showDialog<bool>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.delete_sweep_outlined),
              SizedBox(width: 8),
              Expanded(child: Text('Clear History Temuan')),
            ],
          ),
          content: SizedBox(
            width: 560,
            height: MediaQuery.sizeOf(context).height * 0.58,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Hanya order yang PDF-nya sudah direlease yang dapat dihapus. '
                  'Foto, data temuan, dan order di cloud akan dihapus permanen.',
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: dipilih.length == history.length,
                  title: const Text('Pilih semua history selesai'),
                  onChanged: (v) => setD(() {
                    dipilih.clear();
                    if (v == true) {
                      dipilih.addAll(history.map((e) => (e['id'] ?? '').toString()));
                    }
                  }),
                ),
                const Divider(),
                Expanded(
                  child: ListView.builder(
                    itemCount: history.length,
                    itemBuilder: (_, i) {
                      final order = history[i];
                      final id = (order['id'] ?? '').toString();
                      return CheckboxListTile(
                        value: dipilih.contains(id),
                        title: Text((order['namaCustomer'] ?? '-').toString()),
                        subtitle: Text(
                          '${order['noPolisi'] ?? '-'} • ${order['jumlahTemuan'] ?? 0} temuan',
                        ),
                        onChanged: (v) => setD(() {
                          if (v == true) {
                            dipilih.add(id);
                          } else {
                            dipilih.remove(id);
                          }
                        }),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dc, false),
              child: const Text('Batal'),
            ),
            FilledButton.icon(
              onPressed: dipilih.isEmpty ? null : () => Navigator.pop(dc, true),
              icon: const Icon(Icons.delete_forever_outlined),
              label: Text('Hapus (${dipilih.length})'),
            ),
          ],
        ),
      ),
    );

    if (konfirmasi != true || dipilih.isEmpty) return;

    final target = history
        .where((e) => dipilih.contains((e['id'] ?? '').toString()))
        .toList();
    await _hapusHistoryTemuanTerpilih(target);
  }

  Widget _temuanServicePage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          elevation: 0,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Temuan Service',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text('Daftar estimasi yang akan diperiksa teknisi.'),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _pilihSaAktif,
                      icon: const Icon(Icons.person_outline, size: 18),
                      label: Text(_labelSaAktif),
                    ),
                    IconButton(
                      tooltip: 'Sinkron Temuan',
                      onPressed: _sinkronTemuanCloud,
                      icon: const Icon(Icons.sync, color: biruUtama),
                    ),
                    OutlinedButton.icon(
                      onPressed: _clearHistoryTemuan,
                      icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                      label: const Text('Clear History'),
                    ),
                    FilledButton.icon(
                      onPressed: _tambahkanEstimasiKeEco,
                      icon: const Icon(Icons.add_task_outlined),
                      label: const Text('Kirim Estimasi'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (ecoEstimasi.isEmpty)
          const Card(
            elevation: 0,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 48, horizontal: 20),
              child: Column(
                children: [
                  Icon(Icons.fact_check_outlined, size: 54, color: Colors.grey),
                  SizedBox(height: 12),
                  Text('Belum ada estimasi di Temuan Service', style: TextStyle(fontWeight: FontWeight.bold)),
                  SizedBox(height: 5),
                  Text('Lengkapi data customer lalu tekan Kirim Estimasi.', textAlign: TextAlign.center),
                ],
              ),
            ),
          )
        else
          ...ecoEstimasi.map(_kartuEcoEstimasi),
      ],
    );
  }

  Widget _kartuEcoEstimasi(Map<String, dynamic> data) {
    final jumlah = (data['jumlahTemuan'] as num?)?.toInt() ?? 0;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _bukaDetailEco(data),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const CircleAvatar(
                backgroundColor: biruMuda,
                child: Icon(Icons.directions_car_outlined, color: biruUtama),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((data['namaCustomer'] ?? '').toString(), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 5),
                    Text('Nomor Polisi : ${data['noPolisi'] ?? '-'}'),
                    Text('No. Telepon/WA : ${data['noTelepon'] ?? '-'}'),
                    Text('Tipe Kendaraan : ${data['tipeKendaraan'] ?? '-'}'),
                    Text('Nomor Rangka : ${data['noRangka'] ?? '-'}'),
                    Text('Nama SA : ${data['namaSa'] ?? '-'}'),
                    const SizedBox(height: 8),
                    Text(jumlah == 0 ? 'Menunggu Temuan Teknisi' : '$jumlah Temuan', style: TextStyle(color: jumlah == 0 ? Colors.orange.shade800 : biruUtama, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }

  void _bukaDetailEco(Map<String, dynamic> data) {
    final temuan = ((data['temuan'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final dipilih = <int>{};

    showDialog<void>(
      context: context,
      builder: (dc) => StatefulBuilder(
        builder: (context, setD) {
          Widget tombolPesanWa() => FilledButton.icon(
                onPressed: dipilih.isEmpty
                    ? null
                    : () async {
                        final selected = [
                          for (final i in dipilih.toList()..sort()) temuan[i],
                        ];
                        await _kirimPesanWaTemuan(data, selected);
                      },
                icon: const Icon(Icons.chat_outlined),
                label: Text('Kirim Pesan WA (${dipilih.length})'),
              );

          Widget tombolPdfWa() => FilledButton.tonalIcon(
                onPressed: dipilih.isEmpty
                    ? null
                    : () async {
                        final selected = [
                          for (final i in dipilih.toList()..sort()) temuan[i],
                        ];
                        Navigator.pop(dc);
                        await _buatPdfTemuan(data, selected);
                      },
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: Text('Kirim PDF WA (${dipilih.length})'),
              );

          return AlertDialog(
            insetPadding: const EdgeInsets.all(12),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Detail Temuan Service',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 3),
                Text(
                  'Nomor Polisi: ${(data['noPolisi'] ?? '-').toString()}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: biruUtama,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (temuan.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth < 520) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            tombolPesanWa(),
                            const SizedBox(height: 8),
                            tombolPdfWa(),
                          ],
                        );
                      }
                      return Row(
                        children: [
                          Expanded(child: tombolPesanWa()),
                          const SizedBox(width: 8),
                          Expanded(child: tombolPdfWa()),
                        ],
                      );
                    },
                  ),
                ],
              ],
            ),
            content: SizedBox(
              width: 760,
              height: MediaQuery.sizeOf(context).height * 0.72,
              child: temuan.isEmpty
                  ? const Center(child: Text('Belum ada temuan dari teknisi'))
                  : ListView.builder(
                      itemCount: temuan.length,
                      itemBuilder: (context, i) {
                        final f = temuan[i];
                        final foto = (f['foto_url'] ?? f['photo_url'] ?? f['foto'] ?? '').toString();
                        final ket = (f['kondisi'] ?? f['keterangan'] ?? f['deskripsi'] ?? '-').toString();
                        final jasa = _temuanList(f, 'estimasi_jasa');
                        final part = _temuanList(f, 'estimasi_sparepart');
                        final bahan = _temuanList(f, 'estimasi_bahan');
                        final total = _totalKategoriTemuan(jasa) +
                            _totalKategoriTemuan(part) +
                            _totalKategoriTemuan(bahan);
                        final checked = dipilih.contains(i);

                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Checkbox(
                                      value: checked,
                                      onChanged: (v) => setD(() {
                                        if (v == true) {
                                          dipilih.add(i);
                                        } else {
                                          dipilih.remove(i);
                                        }
                                      }),
                                    ),
                                    Expanded(
                                      child: Text(
                                        'Temuan ${i + 1}',
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                      ),
                                    ),
                                    Text(checked ? 'Dipilih untuk PDF' : 'Belum dipilih',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: checked ? biruUtama : Colors.grey.shade600,
                                          fontWeight: checked ? FontWeight.w600 : FontWeight.normal,
                                        )),
                                  ],
                                ),
                                if (foto.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  _fotoTemuanWidget(foto, height: 170),
                                ],
                                const SizedBox(height: 8),
                                Text(ket),
                                const SizedBox(height: 8),
                                Text('Jasa: ${jasa.length} • Spare Part: ${part.length} • Bahan: ${bahan.length}'),
                                const SizedBox(height: 4),
                                Text('Total: ${rupiah(total)}', style: const TextStyle(fontWeight: FontWeight.bold)),
                                const SizedBox(height: 10),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: OutlinedButton.icon(
                                    onPressed: () {
                                      Navigator.pop(dc);
                                      _bukaEditorTemuan(data, f);
                                    },
                                    icon: const Icon(Icons.edit_outlined),
                                    label: const Text('Isi Estimasi'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              if (temuan.isNotEmpty)
                TextButton(
                  onPressed: () => setD(() {
                    if (dipilih.length == temuan.length) {
                      dipilih.clear();
                    } else {
                      dipilih
                        ..clear()
                        ..addAll(List.generate(temuan.length, (i) => i));
                    }
                  }),
                  child: Text(dipilih.length == temuan.length ? 'Batal Pilih Semua' : 'Pilih Semua'),
                ),
              TextButton(onPressed: () => Navigator.pop(dc), child: const Text('Tutup')),
            ],
          );
        },
      ),
    );
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _headerBaru(),
            _tabNavigasi(),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragEnd: (details) {
                  final velocity = details.primaryVelocity ?? 0;
                  if (velocity.abs() < 250) return;
                  setState(() {
                    if (velocity < 0 && _tabAktif < 5) {
                      _tabAktif++;
                    } else if (velocity > 0 && _tabAktif > 0) {
                      _tabAktif--;
                    }
                  });
                },
                child: IndexedStack(
                  index: _tabAktif,
                  children: [
                  _halamanScroll([customerSection(), const SizedBox(height: 14), statusDatabase()]),
                  _halamanScroll([_kategoriJasa()]),
                  _halamanScroll([_kategoriSparePart()]),
                  _halamanScroll([_kategoriBahan()]),
                  _halamanScroll([
                    _rincianTotalBaru(),
                    const SizedBox(height: 16),
                    informasiSection(),
                    const SizedBox(height: 16),
                    pengaturanPdfSection(),
                    const SizedBox(height: 16),
                    pengaturanTemplateWaSection(),
                    const SizedBox(height: 16),
                    pengaturanSpreadsheetSection(),
                  ]),
                    _halamanScroll([_temuanServicePage()]),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _halamanScroll(List<Widget> children) => ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 36),
        children: children,
      );

  Widget _headerBaru() {
    const navy = Color(0xFF073676);
    const red = Color(0xFFE60012);

    return Container(
      width: double.infinity,
      color: navy,
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final mobile = constraints.maxWidth < 700;

          final branding = Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: mobile ? 78 : 150,
                height: mobile ? 76 : 118,
                child: Image.asset(
                  'assets/daihatsu_logo.png',
                  fit: BoxFit.contain,
                ),
              ),
              Container(
                width: 1.3,
                height: mobile ? 64 : 102,
                margin: EdgeInsets.symmetric(horizontal: mobile ? 9 : 18),
                color: navy,
              ),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'ESTIMASI SERVICE',
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: mobile ? 25 : 46,
                                height: .95,
                                fontWeight: FontWeight.w900,
                                color: navy,
                                letterSpacing: .2,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Container(
                              width: mobile ? 190 : 350,
                              height: 3,
                              decoration: BoxDecoration(
                                color: red,
                                borderRadius: BorderRadius.circular(99),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      alignment: Alignment.center,
                      padding: EdgeInsets.symmetric(
                        horizontal: mobile ? 8 : 18,
                        vertical: mobile ? 4 : 7,
                      ),
                      decoration: BoxDecoration(
                        color: navy,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          'DAIHATSU PURWAKARTA',
                          maxLines: 1,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: mobile ? 10 : 19,
                            fontWeight: FontWeight.w700,
                            letterSpacing: mobile ? 1.1 : 2.6,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );

          final actions = Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _headerIcon(Icons.star_outline, 'Simpan Favorit', simpanEstimasiFavorit),
              _headerIcon(Icons.folder_open_outlined, 'Buka Favorit', bukaEstimasiFavorit),
              _headerIcon(Icons.picture_as_pdf_outlined, 'Buat PDF', buatPdfEstimasi),
              Container(width: 1, height: 30, margin: const EdgeInsets.symmetric(horizontal: 4), color: const Color(0xFFB9C7D8)),
              _headerIcon(
                tampilkanDiskon ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                tampilkanDiskon ? 'Sembunyikan diskon' : 'Tampilkan diskon',
                () => setState(() => tampilkanDiskon = !tampilkanDiskon),
              ),
            ],
          );

          return Column(
            children: [
              Container(
                width: double.infinity,
                padding: EdgeInsets.fromLTRB(
                  mobile ? 10 : 22,
                  mobile ? 9 : 16,
                  mobile ? 10 : 22,
                  mobile ? 7 : 14,
                ),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.only(
                    topLeft: Radius.circular(18),
                    topRight: Radius.circular(18),
                  ),
                ),
                child: mobile
                    ? Column(
                        children: [
                          branding,
                          const SizedBox(height: 5),
                          Align(alignment: Alignment.centerRight, child: actions),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(child: branding),
                          const SizedBox(width: 18),
                          actions,
                        ],
                      ),
              ),
              Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(
                  horizontal: mobile ? 10 : 26,
                  vertical: mobile ? 8 : 11,
                ),
                decoration: const BoxDecoration(
                  color: navy,
                  borderRadius: BorderRadius.only(
                    bottomLeft: Radius.circular(18),
                    bottomRight: Radius.circular(18),
                  ),
                ),
                child: mobile
                    ? const Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _InfoHeader(Icons.phone_outlined, '0896 5650 0965'),
                          _InfoHeader(Icons.location_on_outlined, 'Purwakarta'),
                        ],
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _InfoHeader(Icons.phone_outlined, '0896 5650 0965'),
                          _InfoHeader(Icons.location_on_outlined, 'Daihatsu Purwakarta'),
                          _InfoHeader(Icons.handshake_outlined, 'Service Berkualitas, Sahabat Terpercaya'),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _headerIcon(IconData icon, String tooltip, VoidCallback onTap) => IconButton(
        tooltip: tooltip,
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 42, minHeight: 42),
        icon: Icon(icon, color: const Color(0xFF073676), size: 27),
      );

  Widget _tabNavigasi() {
    const tabs = [
      (Icons.assignment_outlined, 'Data Customer'),
      (Icons.build_outlined, 'Jasa'),
      (Icons.settings_outlined, 'Spare Parts'),
      (Icons.water_drop_outlined, 'Bahan'),
      (Icons.calculate_outlined, 'Rincian & Total'),
      (Icons.fact_check_outlined, 'Temuan Service'),
    ];
    return Material(
      color: Colors.white,
      elevation: 2,
      child: SizedBox(
        height: 66,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: List.generate(tabs.length, (i) {
              final aktif = _tabAktif == i;
              return SizedBox(
                width: 118,
                child: InkWell(
                  onTap: () => setState(() => _tabAktif = i),
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(
                        color: aktif ? biruUtama : Colors.transparent,
                        width: 3,
                      )),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(tabs[i].$1, color: aktif ? biruUtama : Colors.black54, size: 22),
                        const SizedBox(height: 3),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            tabs[i].$2,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: aktif ? biruUtama : Colors.black87,
                              fontWeight: aktif ? FontWeight.bold : FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _kategoriJasa() => kategoriSection(
    title: 'JASA', icon: Icons.build, buttonText: '+ Jasa', items: daftarJasa,
    totalLabel: 'Total Jasa', subtotal: subtotalJasa, diskon: diskonJasa, total: totalJasa,
    diskonAkhirPersen: diskonAkhirJasaPersen,
    onEditDiskonAkhir: () => editDiskonAkhir(judul: 'Diskon All Jasa', nilaiAwal: diskonAkhirJasaPersen, onSimpan: (v) => diskonAkhirJasaPersen = v),
    onTambah: bukaPencarianJasa,
  );

  Widget _kategoriSparePart() => kategoriSection(
    title: 'SPARE PART', icon: Icons.settings, buttonText: '+ Spare Part', items: daftarSparePart,
    totalLabel: 'Total Spare Part', subtotal: subtotalSparePart, diskon: diskonSparePart, total: totalSparePart,
    diskonAkhirPersen: diskonAkhirSparePartPersen,
    onEditDiskonAkhir: () => editDiskonAkhir(judul: 'Diskon All Spare Part', nilaiAwal: diskonAkhirSparePartPersen, onSimpan: (v) => diskonAkhirSparePartPersen = v),
    onTambah: loadingExcel ? null : () => bukaPencarianMasterLokal('Cari Spare Part', KategoriEstimasi.sparePart),
  );

  Widget _kategoriBahan() => kategoriSection(
    title: 'BAHAN', icon: Icons.inventory_2, buttonText: '+ Bahan', items: daftarBahan,
    totalLabel: 'Total Bahan', subtotal: subtotalBahan, diskon: diskonBahan, total: totalBahan,
    diskonAkhirPersen: diskonAkhirBahanPersen,
    onEditDiskonAkhir: () => editDiskonAkhir(judul: 'Diskon All Bahan', nilaiAwal: diskonAkhirBahanPersen, onSimpan: (v) => diskonAkhirBahanPersen = v),
    onTambah: loadingExcel ? null : () => bukaPencarianMasterLokal('Cari Bahan', KategoriEstimasi.bahan),
  );

  Widget _rincianTotalBaru() {
    return LayoutBuilder(builder: (context, c) {
      final kiri = Column(children: [
        _tabelRincian('JASA', daftarJasa), const SizedBox(height: 12),
        _tabelRincian('SPARE PARTS', daftarSparePart), const SizedBox(height: 12),
        _tabelRincian('BAHAN / OLI', daftarBahan),
      ]);
      final kanan = _panelTotalBaru();
      if (c.maxWidth < 850) return Column(children: [kiri, const SizedBox(height: 14), kanan]);
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 2, child: kiri), const SizedBox(width: 14), Expanded(child: kanan)]);
    });
  }

  Widget _tabelRincian(String judul, List<ItemEstimasi> items) {
    final total = items.fold<double>(0, (a, b) => a + b.total);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white, border: Border.all(color: const Color(0xFFD6E0EC)), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(judul, style: const TextStyle(color: Color(0xFF073676), fontWeight: FontWeight.w900, fontSize: 16)),
        const SizedBox(height: 8),
        if (items.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('Belum ada item', style: TextStyle(color: Colors.grey)))
        else ...items.asMap().entries.map((e) => Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFE7EDF4)))),
          child: Row(children: [
            SizedBox(width: 28, child: Text('${e.key + 1}.')),
            Expanded(flex: 4, child: Text(e.value.nama, style: const TextStyle(fontWeight: FontWeight.w600))),
            SizedBox(width: 52, child: Text(formatQty(e.value.qty), textAlign: TextAlign.center)),
            Expanded(flex: 2, child: Text(rupiah(e.value.harga.toDouble()), textAlign: TextAlign.right)),
            if (tampilkanDiskon) SizedBox(width: 55, child: Text('${formatQty(e.value.diskonPersen)}%', textAlign: TextAlign.center)),
            Expanded(flex: 2, child: Text(rupiah(e.value.total), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.bold))),
          ]),
        )),
        const SizedBox(height: 8),
        Row(children: [Expanded(child: Text('TOTAL $judul', style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF073676)))), Text(rupiah(total), style: const TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF073676)))]),
      ]),
    );
  }

  Widget _panelTotalBaru() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(color: Colors.white, border: Border.all(color: const Color(0xFFD6E0EC)), borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7), decoration: BoxDecoration(color: const Color(0xFF073676), borderRadius: BorderRadius.circular(7)), child: const Text('TOTAL', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
        const SizedBox(height: 18),
        _ringkasRow('Total Jasa', totalJasa),
        _ringkasRow('Total Spare Parts', totalSparePart),
        _ringkasRow('Total Bahan', totalBahan),
        const Divider(height: 28),
        _ringkasRow('Subtotal', totalSebelumDiskonGrand),
        if (tampilkanDiskon) ...[
          Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Row(children: [const Expanded(child: Text('Diskon Total (%)')), InkWell(onTap: () => editDiskonAkhir(judul: 'Diskon Grand Total', nilaiAwal: diskonGrandPersen, onSimpan: (v) => diskonGrandPersen = v), child: Text('${formatQty(diskonGrandPersen)} %', style: const TextStyle(fontWeight: FontWeight.bold, color: biruUtama)))])),
          _ringkasRow('Diskon Total (Rp)', diskonGrand),
        ],
        const Divider(height: 28),
        Row(children: [const Expanded(child: Text('GRAND TOTAL', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF073676)))), Text(rupiah(grandTotal), style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900, color: Color(0xFF073676)))]),
      ]),
    );
  }

  Widget _ringkasRow(String label, double nilai) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(children: [Expanded(child: Text(label)), Text(rupiah(nilai), style: const TextStyle(fontWeight: FontWeight.w600))]),
  );

  Widget statusDatabase() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isPhone = constraints.maxWidth < 600;

        final status = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (loadingExcel)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(Icons.check_circle, color: Colors.green),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                statusExcel,
                softWrap: true,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        );

        final tombol = isPhone
            ? Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => bukaEditDatabase(),
                      icon: const Icon(Icons.edit_note, size: 18),
                      label: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('Edit Database'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: loadingExcel ? null : importDatabaseExcel,
                      icon: const Icon(Icons.upload_file, size: 18),
                      label: const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('Import Excel'),
                      ),
                    ),
                  ),
                ],
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => bukaEditDatabase(),
                    icon: const Icon(Icons.edit_note, size: 18),
                    label: const Text('Edit Database'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: loadingExcel ? null : importDatabaseExcel,
                    icon: const Icon(Icons.upload_file, size: 18),
                    label: const Text('Import Excel'),
                  ),
                ],
              );

        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: loadingExcel ? Colors.orange.shade50 : Colors.green.shade50,
            borderRadius: BorderRadius.circular(12),
          ),
          child: isPhone
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    status,
                    const SizedBox(height: 14),
                    tombol,
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: status),
                    const SizedBox(width: 10),
                    tombol,
                  ],
                ),
        );
      },
    );
  }

  // ============================================================
  // CUSTOMER
  // ============================================================

  Widget customerSection() {
    return cardSection(
      title: '1. Data Customer',
      icon: Icons.person,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth <= 700) {
            return Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed:
                        sedangAmbilCustomer ? null : ambilCustomerSpreadsheet,
                    icon: sedangAmbilCustomer
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.cloud_download_outlined),
                    label: Text(
                      sedangAmbilCustomer
                          ? 'Mengambil Data...'
                          : 'Ambil Data Customer',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                customerField(
                  namaCustomerController,
                  'Nama Customer',
                  Icons.person_outline,
                ),
                const SizedBox(height: 12),
                customerField(
                  noPolisiController,
                  'No. Polisi',
                  Icons.directions_car,
                ),
                const SizedBox(height: 12),
                customerField(
                  noTeleponController,
                  'No. Telepon / WhatsApp',
                  Icons.phone_outlined,
                ),
                const SizedBox(height: 12),
                customerField(
                  kilometerController,
                  'Kilometer',
                  Icons.speed,
                ),
                const SizedBox(height: 12),
                tipeKendaraanField(),
                const SizedBox(height: 12),
                customerField(
                  noRangkaController,
                  'No. Rangka',
                  Icons.numbers,
                ),
              ],
            );
          }

          return Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed:
                      sedangAmbilCustomer ? null : ambilCustomerSpreadsheet,
                  icon: sedangAmbilCustomer
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.cloud_download_outlined),
                  label: Text(
                    sedangAmbilCustomer
                        ? 'Mengambil Data...'
                        : 'Ambil Data Customer',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: customerField(
                      namaCustomerController,
                      'Nama Customer',
                      Icons.person_outline,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: customerField(
                      noPolisiController,
                      'No. Polisi',
                      Icons.directions_car,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: customerField(
                      kilometerController,
                      'Kilometer',
                      Icons.speed,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: tipeKendaraanField(),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: customerField(
                      noRangkaController,
                      'No. Rangka',
                      Icons.numbers,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: customerField(
                      noTeleponController,
                      'No. Telepon / WhatsApp',
                      Icons.phone_outlined,
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }


  Widget tipeKendaraanField() {
    final current = tipeKendaraanController.text.trim();
    final tipe = [...daftarTipeKendaraan];
    if (current.isNotEmpty && !tipe.contains(current)) {
      tipe.insert(0, current);
    }
    return DropdownButtonFormField<String>(
      value: current.isNotEmpty ? current : null,
      decoration: const InputDecoration(labelText:'Tipe Kendaraan',prefixIcon:Icon(Icons.car_repair)),
      hint: const Text('Pilih tipe kendaraan'),
      items: tipe.map((e)=>DropdownMenuItem(value:e,child:Text(e))).toList(),
      onChanged:(v){
        if(v==null)return;
        final lama=tipeKendaraanController.text.trim();
        if(lama.isNotEmpty && lama!=v && daftarJasa.isNotEmpty){
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('Tipe kendaraan berubah. Periksa kembali Jasa yang sudah dipilih.')));
        }
        setState(()=>tipeKendaraanController.text=v);
      },
    );
  }

  Widget customerField(
    TextEditingController controller,
    String label,
    IconData icon,
  ) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon),
      ),
    );
  }

  // ============================================================
  // ESTIMASI
  // ============================================================

  Widget estimasiSection() {
    return cardSection(
      title: '2. Estimasi',
      icon: Icons.receipt_long,
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: simpanEstimasiFavorit,
                      icon: const Icon(Icons.star_outline),
                      label: const Text('Simpan Favorit'),
                    ),
                    OutlinedButton.icon(
                      onPressed: bukaEstimasiFavorit,
                      icon: const Icon(Icons.folder_open_outlined),
                      label: const Text('Buka Favorit'),
                    ),
                    FilledButton.icon(
                      onPressed: buatPdfEstimasi,
                      icon: const Icon(Icons.picture_as_pdf_outlined),
                      label: const Text('Buat PDF'),
                    ),
                  ],
                ),
              ),
              IconButton.outlined(
                tooltip: tampilkanDiskon
                    ? 'Sembunyikan diskon'
                    : 'Tampilkan diskon',
                onPressed: () => setState(
                  () => tampilkanDiskon = !tampilkanDiskon,
                ),
                icon: Icon(
                  tampilkanDiskon
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          kategoriSection(
            title: 'JASA',
            icon: Icons.build,
            buttonText: '+ Jasa',
            items: daftarJasa,
            totalLabel: 'Total Jasa',
            subtotal: subtotalJasa,
            diskon: diskonJasa,
            total: totalJasa,
            diskonAkhirPersen: diskonAkhirJasaPersen,
            onEditDiskonAkhir: () => editDiskonAkhir(
              judul: 'Diskon All Jasa',
              nilaiAwal: diskonAkhirJasaPersen,
              onSimpan: (v) => diskonAkhirJasaPersen = v,
            ),
            onTambah: bukaPencarianJasa,
          ),
          const SizedBox(height: 20),
          kategoriSection(
            title: 'SPARE PART',
            icon: Icons.settings,
            buttonText: '+ Spare Part',
            items: daftarSparePart,
            totalLabel: 'Total Spare Part',
            subtotal: subtotalSparePart,
            diskon: diskonSparePart,
            total: totalSparePart,
            diskonAkhirPersen: diskonAkhirSparePartPersen,
            onEditDiskonAkhir: () => editDiskonAkhir(
              judul: 'Diskon All Spare Part',
              nilaiAwal: diskonAkhirSparePartPersen,
              onSimpan: (v) => diskonAkhirSparePartPersen = v,
            ),
            onTambah: loadingExcel
                ? null
                : () => bukaPencarian(
                      'Cari Spare Part',
                      spareParts,
                      KategoriEstimasi.sparePart,
                    ),
          ),
          const SizedBox(height: 20),
          kategoriSection(
            title: 'BAHAN',
            icon: Icons.inventory_2,
            buttonText: '+ Bahan',
            items: daftarBahan,
            totalLabel: 'Total Bahan',
            subtotal: subtotalBahan,
            diskon: diskonBahan,
            total: totalBahan,
            diskonAkhirPersen: diskonAkhirBahanPersen,
            onEditDiskonAkhir: () => editDiskonAkhir(
              judul: 'Diskon All Bahan',
              nilaiAwal: diskonAkhirBahanPersen,
              onSimpan: (v) => diskonAkhirBahanPersen = v,
            ),
            onTambah: loadingExcel
                ? null
                : () => bukaPencarian(
                      'Cari Bahan',
                      bahan,
                      KategoriEstimasi.bahan,
                    ),
          ),
        ],
      ),
    );
  }

  Widget kategoriSection({
    required String title,
    required IconData icon,
    required String buttonText,
    required List<ItemEstimasi> items,
    required String totalLabel,
    required double subtotal,
    required double diskon,
    required double total,
    required double diskonAkhirPersen,
    required VoidCallback onEditDiskonAkhir,
    required VoidCallback? onTambah,
  }) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFD9E4EF)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: const BoxDecoration(
              color: biruMuda,
              borderRadius: BorderRadius.vertical(top: Radius.circular(13)),
            ),
            child: Row(
              children: [
                Icon(icon, color: biruUtama),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: biruUtama,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: onTambah,
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(buttonText),
                ),
              ],
            ),
          ),
          if (items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'Belum ada item',
                style: TextStyle(color: Colors.grey),
              ),
            )
          else
            ...items.map(estimasiItem),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 14,
            ),
            decoration: const BoxDecoration(
              color: Color(0xFFF8FAFD),
              borderRadius:
                  BorderRadius.vertical(bottom: Radius.circular(13)),
            ),
            child: tampilkanDiskon
                ? Column(
                    children: [
                      kategoriTotalRow('Subtotal', subtotal),
                      const SizedBox(height: 5),
                      kategoriTotalRow(
                        'Diskon',
                        diskon,
                        negatif: true,
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          const Expanded(
                            child: Text('Diskon All (%)'),
                          ),
                          Text(
                            '${formatQty(diskonAkhirPersen)}%',
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 6),
                          IconButton(
                            tooltip: 'Edit diskon all',
                            onPressed: onEditDiskonAkhir,
                            icon: const Icon(
                              Icons.edit_outlined,
                              size: 18,
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 18),
                      kategoriTotalRow(
                        totalLabel,
                        total,
                        utama: true,
                      ),
                    ],
                  )
                : kategoriTotalRow(totalLabel, total, utama: true),
          ),
        ],
      ),
    );
  }

  Widget kategoriTotalRow(
    String label,
    double value, {
    bool negatif = false,
    bool utama = false,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontWeight:
                  utama ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ),
        Text(
          negatif && value > 0 ? '-${rupiah(value)}' : rupiah(value),
          style: TextStyle(
            color: utama ? biruUtama : Colors.black87,
            fontWeight:
                utama ? FontWeight.bold : FontWeight.w600,
            fontSize: utama ? 16 : 14,
          ),
        ),
      ],
    );
  }

  // ============================================================
  // ITEM + QTY DESIMAL
  // ============================================================

  Widget estimasiItem(ItemEstimasi item) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFFE5EBF2)),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final mobile = constraints.maxWidth < 760;

          final infoItem = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.nama,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${rupiah(item.harga.toDouble())} x ${formatQty(item.qty)}',
                style: const TextStyle(color: Colors.grey),
              ),
              if (tampilkanDiskon && item.diskonPersen > 0) ...[
                const SizedBox(height: 3),
                Text(
                  'Subtotal ${rupiah(item.subtotal)} • '
                  'Diskon ${formatQty(item.diskonPersen)}% '
                  '(-${rupiah(item.nominalDiskon)})',
                  style: const TextStyle(
                    color: Colors.grey,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          );

          final kontrolQty = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Kurangi 1',
                onPressed: item.qty <= 1
                    ? null
                    : () {
                        setState(() {
                          final hasil = item.qty - 1;
                          if (hasil > 0) item.qty = hasil;
                        });
                      },
                icon: const Icon(Icons.remove_circle_outline),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => editQty(item),
                child: Container(
                  constraints: const BoxConstraints(minWidth: 60),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: biruMuda,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFFBBD7F2),
                    ),
                  ),
                  child: Text(
                    formatQty(item.qty),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: biruUtama,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Tambah 1',
                onPressed: () => setState(() => item.qty += 1),
                icon: const Icon(Icons.add_circle_outline),
              ),
            ],
          );

          final kontrolDiskon = InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => editDiskon(item),
            child: Container(
              constraints: const BoxConstraints(minWidth: 76),
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF7E6),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: const Color(0xFFFFD58A),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.percent,
                    size: 15,
                    color: Colors.orange,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    formatQty(item.diskonPersen),
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          );

          final hargaTotal = Text(
            rupiah(item.total),
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 15,
            ),
          );

          final hapus = IconButton(
            tooltip: 'Hapus',
            onPressed: () {
              setState(() {
                itemEstimasi.removeWhere((e) => e.id == item.id);
              });
            },
            icon: const Icon(
              Icons.delete_outline,
              color: Colors.red,
            ),
          );

          if (mobile) {
            // Layout HP dibuat satu baris: nama item | qty | harga total | hapus.
            // Ini mencegah quantity dan harga turun/menumpuk ke bawah.
            final kontrolQtyMobile = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 30,
                  height: 34,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Kurangi 1',
                    onPressed: item.qty <= 1
                        ? null
                        : () {
                            setState(() {
                              final hasil = item.qty - 1;
                              if (hasil > 0) item.qty = hasil;
                            });
                          },
                    icon: const Icon(Icons.remove_circle_outline, size: 19),
                  ),
                ),
                InkWell(
                  borderRadius: BorderRadius.circular(7),
                  onTap: () => editQty(item),
                  child: Container(
                    width: 42,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: biruMuda,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: const Color(0xFFBBD7F2)),
                    ),
                    child: Text(
                      formatQty(item.qty),
                      style: const TextStyle(
                        color: biruUtama,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 30,
                  height: 34,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Tambah 1',
                    onPressed: () => setState(() => item.qty += 1),
                    icon: const Icon(Icons.add_circle_outline, size: 19),
                  ),
                ),
              ],
            );

            final hargaTotalMobile = Text(
              rupiah(item.total),
              maxLines: 1,
              overflow: TextOverflow.visible,
              textAlign: TextAlign.right,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            );

            final hapusMobile = SizedBox(
              width: 32,
              height: 36,
              child: IconButton(
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                tooltip: 'Hapus',
                onPressed: () {
                  setState(() {
                    itemEstimasi.removeWhere((e) => e.id == item.id);
                  });
                },
                icon: const Icon(Icons.delete_outline, color: Colors.red, size: 19),
              ),
            );

            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: DefaultTextStyle.merge(
                    style: const TextStyle(fontSize: 12),
                    child: infoItem,
                  ),
                ),
                const SizedBox(width: 6),
                kontrolQtyMobile,
                if (tampilkanDiskon) ...[
                  const SizedBox(width: 4),
                  Flexible(child: kontrolDiskon),
                ],
                const SizedBox(width: 8),
                hargaTotalMobile,
                const SizedBox(width: 2),
                hapusMobile,
              ],
            );
          }

          return Row(
            children: [
              Expanded(child: infoItem),
              kontrolQty,
              if (tampilkanDiskon) ...[
                const SizedBox(width: 10),
                kontrolDiskon,
              ],
              const SizedBox(width: 15),
              SizedBox(width: 130, child: hargaTotal),
              const SizedBox(width: 8),
              hapus,
            ],
          );
        },
      ),
    );
  }

  Widget informasiSection() {
    return cardSection(
      title: '3. Keterangan & Informasi',
      icon: Icons.message_outlined,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final mobile = constraints.maxWidth < 760;
          final keterangan = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Keterangan :', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text('1. Apabila terdapat penambahan diluar estimasi maka akan diberitahukan terlebih dahulu'),
              const Text('2. Estimasi biaya ini bukan bukti pembayaran'),
              const Text('3. Harga sudah termasuk PPN'),
              Text('4. Pembayaran dapat ditransfer ke Rek. ${namaRekeningController.text} - ${namaBankController.text}'),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.blueAccent, style: flutter.BorderStyle.solid),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    infoLine('Nomor Rekening', nomorRekeningController.text),
                    infoLine('Nama Rekening', namaRekeningController.text),
                    infoLine('Bank', namaBankController.text),
                    const SizedBox(height: 4),
                    const Text('*Data rekening dapat berubah sewaktu-waktu', style: TextStyle(color: biruUtama, fontStyle: FontStyle.italic, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ],
          );
          final advisor = Column(
            children: [
              Text('Purwakarta, ${_tanggalIndonesia(DateTime.now())}'),
              const SizedBox(height: 12),
              Container(
                width: 270,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(border: Border.all(color: Colors.black54)),
                child: Column(
                  children: [
                    const Text('SERVICE ADVISOR', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 24),
                    Text(namaServiceAdvisorController.text, style: const TextStyle(fontWeight: FontWeight.bold)),
                    Text('Telp/WA : ${noWaServiceAdvisorController.text}'),
                  ],
                ),
              ),
            ],
          );
          if (mobile) return Column(children: [keterangan, const SizedBox(height: 20), advisor]);
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 3, child: keterangan), const SizedBox(width: 30), Expanded(flex: 2, child: advisor)]);
        },
      ),
    );
  }

  Widget infoLine(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(children: [SizedBox(width: 140, child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold))), const Text(':  '), Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600)))]),
  );

  Widget pengaturanPdfSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.white, border: Border.all(color: biruUtama), borderRadius: BorderRadius.circular(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [Icon(Icons.settings, color: biruUtama), SizedBox(width: 8), Text('PENGATURAN PDF (dapat diubah)', style: TextStyle(color: biruUtama, fontWeight: FontWeight.bold))]),
          const SizedBox(height: 14),
          LayoutBuilder(builder: (context, constraints) {
            final mobile = constraints.maxWidth < 760;
            final kiri = Column(children: [pdfSettingField('Nama Service Advisor', namaServiceAdvisorController), const SizedBox(height: 8), pdfSettingField('No. Telp/WA', noWaServiceAdvisorController)]);
            final kanan = Column(children: [pdfSettingField('Nama Rekening', namaRekeningController), const SizedBox(height: 8), pdfSettingField('Nama Bank', namaBankController), const SizedBox(height: 8), pdfSettingField('Nomor Rekening', nomorRekeningController)]);
            if (mobile) return Column(children: [kiri, const SizedBox(height: 8), kanan]);
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: kiri), const SizedBox(width: 30), Expanded(child: kanan)]);
          }),
          const SizedBox(height: 10),
          Align(alignment: Alignment.centerRight, child: FilledButton.icon(onPressed: () => setState(() {}), icon: const Icon(Icons.save_outlined), label: const Text('Terapkan'))),
        ],
      ),
    );
  }


  Widget pengaturanTemplateWaSection() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: biruUtama),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(children: [
            Icon(Icons.chat_outlined, color: biruUtama),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'TEMPLATE PESAN WHATSAPP TEMUAN',
                style: TextStyle(color: biruUtama, fontWeight: FontWeight.bold),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          const Text(
            'Variabel: {nama}, {nopol}, {tipe}, {temuan}, {total}, {sa}. '
            'Variabel akan diganti otomatis dengan data estimasi.',
            style: TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: templateWaTemuanController,
            minLines: 10,
            maxLines: 18,
            decoration: const InputDecoration(
              labelText: 'Template Pesan',
              alignLabelWithHint: true,
              prefixIcon: Padding(
                padding: EdgeInsets.only(bottom: 150),
                child: Icon(Icons.message_outlined),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: () => setState(() {
                  templateWaTemuanController.text = _templateWaTemuanDefault;
                }),
                icon: const Icon(Icons.restart_alt),
                label: const Text('Reset Template'),
              ),
              FilledButton.icon(
                onPressed: _simpanTemplateWaTemuan,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Simpan Template'),
              ),
            ],
          ),
        ],
      ),
    );
  }


  Widget pengaturanSpreadsheetSection() {
    final namaAktifController = _namaSaSpreadsheetAktif;
    final linkAktifController = _linkSaSpreadsheetAktif;
    final labelDefault = 'SA $saSpreadsheetTerpilih';
    final namaAktif = namaAktifController.text.trim().isEmpty
        ? labelDefault
        : namaAktifController.text.trim();

    return cardSection(
      title: '4. Update Spreadsheet SAP',
      icon: Icons.table_view_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Operational Number akan ditulis sama pada seluruh baris Spare Part dan Bahan. '
            'Data lama di Spreadsheet akan diganti oleh data estimasi aktif.',
            style: TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: operationalNumberController,
            decoration: const InputDecoration(
              labelText: 'Operational Number',
              hintText: 'Contoh: 00123456',
              prefixIcon: Icon(Icons.numbers),
            ),
          ),
          const SizedBox(height: 14),
          SegmentedButton<int>(
            segments: [
              ButtonSegment(
                value: 1,
                label: Text(
                  namaSa1Controller.text.trim().isEmpty
                      ? 'SA 1'
                      : namaSa1Controller.text.trim(),
                ),
              ),
              ButtonSegment(
                value: 2,
                label: Text(
                  namaSa2Controller.text.trim().isEmpty
                      ? 'SA 2'
                      : namaSa2Controller.text.trim(),
                ),
              ),
              ButtonSegment(
                value: 3,
                label: Text(
                  namaSa3Controller.text.trim().isEmpty
                      ? 'SA 3'
                      : namaSa3Controller.text.trim(),
                ),
              ),
            ],
            selected: {saSpreadsheetTerpilih},
            onSelectionChanged: (v) {
              setState(() => saSpreadsheetTerpilih = v.first);
            },
          ),
          const SizedBox(height: 16),

          // Hanya pengaturan SA yang sedang dipilih yang ditampilkan.
          TextField(
            key: ValueKey('nama_sa_$saSpreadsheetTerpilih'),
            controller: namaAktifController,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Nama SA $saSpreadsheetTerpilih',
              prefixIcon: const Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: ValueKey('link_sa_$saSpreadsheetTerpilih'),
            controller: linkAktifController,
            decoration: InputDecoration(
              labelText: 'Link Update Spreadsheet SA $saSpreadsheetTerpilih',
              hintText: 'URL Web App Google Apps Script',
              prefixIcon: const Icon(Icons.link),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                onPressed: simpanPengaturanSpreadsheet,
                icon: const Icon(Icons.save_outlined),
                label: const Text('Simpan Pengaturan'),
              ),
              FilledButton.icon(
                onPressed: sedangUpdateSpreadsheet ? null : updateSpreadsheet,
                icon: sedangUpdateSpreadsheet
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync),
                label: Text(
                  sedangUpdateSpreadsheet
                      ? 'Mengupdate...'
                      : 'Update Spreadsheet $namaAktif',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget pdfSettingField(String label, TextEditingController controller) {
    return Row(children: [SizedBox(width: 145, child: Text(label)), const Text(':  '), Expanded(child: SizedBox(height: 42, child: TextField(controller: controller, onChanged: (_) => setState(() {}), decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)))))]);
  }

  // ============================================================
  // GRAND TOTAL
  // ============================================================

  Widget grandTotalSection() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4C2),
        border: Border.all(color: const Color(0xFFFFB300)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          if (!tampilkanDiskon)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(children: [
                const Expanded(child: Text('GRAND TOTAL', style: TextStyle(fontWeight: FontWeight.bold))),
                Text(rupiah(grandTotal), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              ]),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(children: [
                const Expanded(child: Text('GRAND TOTAL (Sebelum Diskon Grand)', style: TextStyle(fontWeight: FontWeight.bold))),
                Text(rupiah(totalSebelumDiskonGrand), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              ]),
            ),
            const Divider(height: 1, color: Color(0xFFFFB300)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(children: [
                const Text('Diskon Grand Total'),
                const SizedBox(width: 18),
                InkWell(
                  onTap: () => editDiskonAkhir(judul: 'Diskon Grand Total', nilaiAwal: diskonGrandPersen, onSimpan: (v) => diskonGrandPersen = v),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      border: Border.all(color: const Color(0xFFD8E2EE)),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text('${formatQty(diskonGrandPersen)} %'),
                  ),
                ),
                const Spacer(),
                Text('Diskon   ${rupiah(diskonGrand)}', style: const TextStyle(fontWeight: FontWeight.w600)),
              ]),
            ),
            const Divider(height: 1, color: Color(0xFFFFB300)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(children: [
                const Expanded(child: Text('GRAND TOTAL (Setelah Diskon Grand)', style: TextStyle(fontWeight: FontWeight.bold))),
                Text(rupiah(grandTotal), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              ]),
            ),
          ],
        ],
      ),
    );
  }

  Widget totalRow(
    String label,
    double value, {
    bool negatif = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: 4,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
              ),
            ),
          ),
          Text(
            negatif && value > 0 ? '-${rupiah(value)}' : rupiah(value),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // CARD
  // ============================================================

  Widget cardSection({
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: 0.05,
            ),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                icon,
                color: biruUtama,
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: biruUtama,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

// ============================================================
// FORMAT QTY
// ============================================================

String formatQty(double qty) {
  if (qty == qty.roundToDouble()) {
    return qty.toInt().toString();
  }

  String hasil = qty.toStringAsFixed(3);

  while (hasil.endsWith('0')) {
    hasil = hasil.substring(
      0,
      hasil.length - 1,
    );
  }

  if (hasil.endsWith('.')) {
    hasil = hasil.substring(
      0,
      hasil.length - 1,
    );
  }

  return hasil.replaceAll('.', ',');
}

// ============================================================
// FORMAT RUPIAH
// ============================================================

String rupiah(double value) {
  final angka = value.round().toString();
  final buffer = StringBuffer();

  for (int i = 0; i < angka.length; i++) {
    final posisi = angka.length - i;

    buffer.write(angka[i]);

    if (posisi > 1 && posisi % 3 == 1) {
      buffer.write('.');
    }
  }

  return 'Rp ${buffer.toString()}';
}
