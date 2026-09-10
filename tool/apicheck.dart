import 'package:markdown/markdown.dart' as md;

void main() {
  for (final (name, doc) in [
    ('default', md.Document()),
    ('noencode', md.Document(encodeHtml: false)),
  ]) {
    for (final src in ['a &amp; b\n', 'a &lt; b\n', 'a < b\n']) {
      final nodes = doc.parse(src);
      print('$name | ${src.padRight(12)} => "${nodes.first.textContent}"');
    }
  }
}
