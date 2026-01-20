import 'package:flutter_test/flutter_test.dart';
import 'package:password/core/utils/import_export_helper.dart';
import 'package:password/features/vault/domain/models/vault_item.dart';

void main() {
  group('LastPass CSV Parsing Tests', () {
    test('Should parse standard LastPass CSV correctly', () {
      const csvContent = 'url,username,password,extra,name,grouping,fav\n'
          'https://google.com,user@gmail.com,password123,some note,Google,Social,1\n'
          'https://github.com,gituser,gitpass,,GitHub,Work,0';

      final items = ImportExportHelper.parseLastPassCsv(csvContent);

      expect(items.length, 2);
      
      expect(items[0].title, 'Google');
      expect(items[0].username, 'user@gmail.com');
      expect(items[0].password, 'password123');
      expect(items[0].url, 'https://google.com');
      expect(items[0].note, 'some note');
      expect(items[0].category, 'Social');
      expect(items[0].isFavorite, true);

      expect(items[1].title, 'GitHub');
      expect(items[1].username, 'gituser');
      expect(items[1].password, 'gitpass');
      expect(items[1].url, 'https://github.com');
      expect(items[1].note, '');
      expect(items[1].category, 'Work');
      expect(items[1].isFavorite, false);
    });

    test('Should handle CSV without header', () {
      const csvContent = 'https://google.com,user@gmail.com,password123,note,Google,Social,1';
      final items = ImportExportHelper.parseLastPassCsv(csvContent);

      expect(items.length, 1);
      expect(items[0].title, 'Google');
    });

    test('Should handle quoted fields and commas in notes', () {
      const csvContent = 'url,username,password,extra,name,grouping,fav\n'
          '"https://site.com","user","pass","note with , comma","Site","Group",0';
      
      final items = ImportExportHelper.parseLastPassCsv(csvContent);

      expect(items.length, 1);
      expect(items[0].note, 'note with , comma');
    });

    test('Should use URL if name is empty', () {
      const csvContent = 'url,username,password,extra,name,grouping,fav\n'
          'https://anonymous.com,user,pass,,,Group,0';
      
      final items = ImportExportHelper.parseLastPassCsv(csvContent);

      expect(items.length, 1);
      expect(items[0].title, 'https://anonymous.com');
    });
  });
}
