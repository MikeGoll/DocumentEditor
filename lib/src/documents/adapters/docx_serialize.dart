part of 'docx_adapter.dart';

// Serialization side of the [DocxAdapter]: builds the XML parts of a
// .docx package from a list of Quill lines.

extension on DocxAdapter {
  String _contentTypesXml() {
    final b = XmlBuilder();
    b.declaration(encoding: 'UTF-8');
    b.element(
      'Types',
      namespacePrefix: '',
      namespaceUris: {'': DocxAdapter._contentTypesNs},
      nest: () {
        b.element(
          'Default',
          namespaceUri: DocxAdapter._contentTypesNs,
          attributes: const {
            'Extension': 'rels',
            'ContentType':
                'application/vnd.openxmlformats-package.relationships+xml',
          },
        );
        b.element(
          'Default',
          namespaceUri: DocxAdapter._contentTypesNs,
          attributes: const {
            'Extension': 'xml',
            'ContentType': 'application/xml',
          },
        );
        const overrides = [
          (
            '/word/document.xml',
            'application/vnd.openxmlformats-officedocument'
                '.wordprocessingml.document.main+xml',
          ),
          (
            '/word/styles.xml',
            'application/vnd.openxmlformats-officedocument'
                '.wordprocessingml.styles+xml',
          ),
          (
            '/word/numbering.xml',
            'application/vnd.openxmlformats-officedocument'
                '.wordprocessingml.numbering+xml',
          ),
        ];
        for (final (part, type) in overrides) {
          b.element(
            'Override',
            namespaceUri: DocxAdapter._contentTypesNs,
            attributes: {'PartName': part, 'ContentType': type},
          );
        }
      },
    );
    return b.buildDocument().toXmlString();
  }

  String _rootRelsXml() {
    final b = XmlBuilder();
    b.declaration(encoding: 'UTF-8');
    b.element(
      'Relationships',
      namespacePrefix: '',
      namespaceUris: {'': DocxAdapter._packageNs},
      nest: () {
        b.element(
          'Relationship',
          namespaceUri: DocxAdapter._packageNs,
          attributes: const {
            'Id': 'rId1',
            'Type': '${DocxAdapter._relsNs}/officeDocument',
            'Target': 'word/document.xml',
          },
        );
      },
    );
    return b.buildDocument().toXmlString();
  }

  String _documentRelsXml() {
    final b = XmlBuilder();
    b.declaration(encoding: 'UTF-8');
    b.element(
      'Relationships',
      namespacePrefix: '',
      namespaceUris: {'': DocxAdapter._packageNs},
      nest: () {
        const rels = [
          ('rId1', '${DocxAdapter._relsNs}/styles', 'styles.xml'),
          ('rId2', '${DocxAdapter._relsNs}/numbering', 'numbering.xml'),
        ];
        for (final (id, type, target) in rels) {
          b.element(
            'Relationship',
            namespaceUri: DocxAdapter._packageNs,
            attributes: {'Id': id, 'Type': type, 'Target': target},
          );
        }
      },
    );
    return b.buildDocument().toXmlString();
  }

  String _stylesXml() {
    final b = XmlBuilder();
    b.declaration(encoding: 'UTF-8');
    b.element(
      'styles',
      namespacePrefix: 'w',
      namespaceUris: {'w': DocxAdapter._wordNs},
      nest: () {
        const w = DocxAdapter._wordNs;
        b.element(
          'docDefaults',
          namespaceUri: w,
          nest: () {
            b.element('rPrDefault', namespaceUri: w, nest: () {
              b.element('rPr', namespaceUri: w, nest: () {
                b.element('rFonts', namespaceUri: w, attributes: const {
                  'w:ascii': 'Calibri',
                  'w:hAnsi': 'Calibri',
                });
                b.element(
                  'sz',
                  namespaceUri: w,
                  attributes: const {'w:val': '22'},
                );
              });
            });
          },
        );
        b.element(
          'style',
          namespaceUri: w,
          attributes: const {
            'w:type': 'paragraph',
            'w:default': '1',
            'w:styleId': 'Normal',
          },
          nest: () {
            b.element(
              'name',
              namespaceUri: w,
              attributes: const {'w:val': 'Normal'},
            );
          },
        );
        const headingSizes = [72, 56, 44, 36, 32, 32];
        for (var level = 1; level <= 6; level++) {
          b.element(
            'style',
            namespaceUri: w,
            attributes: {
              'w:type': 'paragraph',
              'w:styleId': 'Heading$level',
            },
            nest: () {
              b.element(
                'name',
                namespaceUri: w,
                attributes: {'w:val': 'heading $level'},
              );
              b.element(
                'basedOn',
                namespaceUri: w,
                attributes: const {'w:val': 'Normal'},
              );
              b.element('rPr', namespaceUri: w, nest: () {
                b.element('b', namespaceUri: w);
                b.element(
                  'sz',
                  namespaceUri: w,
                  attributes: {
                    'w:val': headingSizes[level - 1].toString(),
                  },
                );
              });
            },
          );
        }
      },
    );
    return b.buildDocument().toXmlString();
  }

  String _numberingXml() {
    final b = XmlBuilder();
    b.declaration(encoding: 'UTF-8');
    b.element(
      'numbering',
      namespacePrefix: 'w',
      namespaceUris: {'w': DocxAdapter._wordNs},
      nest: () {
        const w = DocxAdapter._wordNs;
        // Abstract numbering 1: bullets, 2: decimals.
        const abstracts = [
          ('1', 'bullet', '\u2022'),
          ('2', 'decimal', '%1.'),
        ];
        for (final (abstractId, format, text) in abstracts) {
          b.element(
            'abstractNum',
            namespaceUri: w,
            attributes: {'w:abstractNumId': abstractId},
            nest: () {
              b.element(
                'lvl',
                namespaceUri: w,
                attributes: const {'w:ilvl': '0'},
                nest: () {
                  b.element(
                    'numFmt',
                    namespaceUri: w,
                    attributes: {'w:val': format},
                  );
                  b.element(
                    'lvlText',
                    namespaceUri: w,
                    attributes: {'w:val': text},
                  );
                },
              );
            },
          );
        }
        const nums = [
          ('1', '1'),
          ('2', '2'),
        ];
        for (final (numId, abstractId) in nums) {
          b.element(
            'num',
            namespaceUri: w,
            attributes: {'w:numId': numId},
            nest: () {
              b.element(
                'abstractNumId',
                namespaceUri: w,
                attributes: {'w:val': abstractId},
              );
            },
          );
        }
      },
    );
    return b.buildDocument().toXmlString();
  }

  String _documentXml(List<DeltaLine> lines) {
    final b = XmlBuilder();
    b.declaration(encoding: 'UTF-8');
    b.element(
      'document',
      namespacePrefix: 'w',
      namespaceUris: {'w': DocxAdapter._wordNs},
      nest: () {
        const w = DocxAdapter._wordNs;
        b.element(
          'body',
          namespaceUri: w,
          nest: () {
            for (final line in lines) {
              _paragraph(b, line, w);
            }
            b.element('sectPr', namespaceUri: w);
          },
        );
      },
    );
    return b.buildDocument().toXmlString();
  }

  void _paragraph(XmlBuilder b, DeltaLine line, String w) {
    b.element(
      'p',
      namespaceUri: w,
      nest: () {
        final header = line.block['header'];
        final list = line.block['list'];
        final hasPPr =
            (header is int && header >= 1 && header <= 6) || list != null;
        if (hasPPr) {
          b.element(
            'pPr',
            namespaceUri: w,
            nest: () {
              if (header is int) {
                b.element(
                  'pStyle',
                  namespaceUri: w,
                  attributes: {'w:val': 'Heading$header'},
                );
              }
              if (list != null) {
                b.element('numPr', namespaceUri: w, nest: () {
                  b.element(
                    'ilvl',
                    namespaceUri: w,
                    attributes: const {'w:val': '0'},
                  );
                  b.element(
                    'numId',
                    namespaceUri: w,
                    attributes: {'w:val': list == 'ordered' ? '2' : '1'},
                  );
                });
              }
            },
          );
        }
        for (final run in line.runs) {
          if (run.text.isEmpty) continue;
          b.element(
            'r',
            namespaceUri: w,
            nest: () {
              final attrs = run.attributes;
              if (attrs.isNotEmpty) {
                b.element(
                  'rPr',
                  namespaceUri: w,
                  nest: () {
                    if (attrs['bold'] == true) {
                      b.element('b', namespaceUri: w);
                    }
                    if (attrs['italic'] == true) {
                      b.element('i', namespaceUri: w);
                    }
                    if (attrs['underline'] == true) {
                      b.element(
                        'u',
                        namespaceUri: w,
                        attributes: const {'w:val': 'single'},
                      );
                    }
                    if (attrs['strike'] == true) {
                      b.element('strike', namespaceUri: w);
                    }
                  },
                );
              }
              b.element(
                't',
                namespaceUri: w,
                attributes: const {'xml:space': 'preserve'},
                nest: () => b.text(run.text),
              );
            },
          );
        }
      },
    );
  }
}
