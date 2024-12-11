import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io';
import 'package:exif/exif.dart';
import 'package:flutter/services.dart';
import 'package:macos_ui/macos_ui.dart';
import './keypress.dart';
import './datatypes.dart';

//todo
//DONE image path, name and exif all in one class
//DONE button navigation
//save selected on file to reduce disk access, every 30 sec with timer
//maybe move exif calculations to when the pic is selected
//screen brightness indicator and lock?

//bug
//if new folder contains files named the same the already loaded files will stay intact, need to clean in between folder changes
//phantom focus thingy (normal keyboard navigation, the app uses a custom one tho but idk how to disable it)

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
          primarySwatch: Colors.blue,
          colorScheme: ColorScheme.fromSeed(
              seedColor: Color.fromARGB(255, 0, 76, 255),
              brightness: Brightness.dark)),
      home: const ImageViewerPage(),
    );
  }
}

class ImageViewerPage extends StatefulWidget {
  const ImageViewerPage({super.key});

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _itemKeys = {};

  List<ImageData> images = [];

  Directory dir = Directory.current;
  Directory tempDir = Directory.current;

  String tempFolder = ".preview_cache";

  bool isProcessing = false;
  bool isIndexing = false;
  int generated = 0;
  int indexed = 0;
  int totalFiles = 0;

  File? bigPreview;

  int lastClicked = 0;

  int deleted = 0;
  int selected = 0;

  void showErrorDialog(BuildContext context, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Error'),
        content: Text(message),
        actions: [
          TextButton(
            child: Text('OK'),
            onPressed: () {
              Navigator.pop(context);
            },
          ),
        ],
      ),
    );
  }

  GlobalKey getKeyForIndex(int index) {
    return _itemKeys.putIfAbsent(index, () => GlobalKey());
  }

  void scrollToSelected(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = getKeyForIndex(index);
      if (key.currentContext != null) {
        Scrollable.ensureVisible(
          key.currentContext!,
          alignment: 0.5, // Center the item in the viewport
          duration: Duration(milliseconds: 200),
          curve: Curves.easeInOut,
        );
      }
    });
  }

  void changeSelectedImage(int n) {
    if (n >= images.length) n = images.length - 1;
    if (n < 0) n = 0;

    setState(() {
      images[lastClicked].isSelected = false;
      lastClicked = n;
      images[lastClicked].isSelected = true;
      bigPreview = File(
          '${dir.path}${Platform.pathSeparator}$tempFolder${Platform.pathSeparator}${images[lastClicked].name}.jpeg');
    });

    scrollToSelected(lastClicked); // Move this outside setState
  }

  void changeSelectedImageByHowMuch(int n) {
    changeSelectedImage(lastClicked + n);
  }

  Future<void> buildCache() async {
    print("build cache start----------------------");
    setState(() {
      isProcessing = true;
      generated = 0;
    });

    try {
      // Create temp directory if it doesn't exist
      final tempDir =
          Directory('${dir.path}${Platform.pathSeparator}$tempFolder');
      if (!await tempDir.exists()) {
        await tempDir.create();
      }

      final result = await Process.start('bash', [
        '-c',
        '''
  cd "${dir.path}" && \
  find . -maxdepth 1 -type f ! -name ".*" | sort -n | \
  xargs -P \$(sysctl -n hw.ncpu) -n 1 bash -c '
    input="\$1"
    output="${tempDir.path}/\$(basename "\$input").jpeg"
    if [ ! -f "\$output" ]; then
      sips -s format jpeg "\$input" --out "\$output" && echo "converted \$output"
    fi
  ' _
  '''
      ]);

      // Listen to stdout to count processed files
      result.stdout.transform(const SystemEncoding().decoder).listen((data) {
        if (data.contains('converted')) {
          print(data);
          setState(() => generated++);
        }
      });

      // Handle any errors
      result.stderr.transform(const SystemEncoding().decoder).listen((data) {
        print('Error: $data');
      });

      await result.exitCode;
    } catch (e) {
      print('Error building cache: $e');
      rethrow;
    } finally {
      setState(() {
        isProcessing = false;
      });
    }
  }

  Future<void> pickFolder() async {
    String? result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      images = [];
      lastClicked = 0;
      setState(() {
        dir = Directory(result);
        isIndexing = true;
        indexed = 0;
      });

      // Count total files first
      await for (final entity in dir.list()) {
        if (entity.path.endsWith(".ARW") || entity.path.endsWith(".NEF")) {
          totalFiles++;
        }
      }

      // Process files
      await for (final entity in dir.list()) {
        await addToList(entity);
        if (entity.path.endsWith(".ARW") || entity.path.endsWith(".NEF")) {
          setState(() {
            indexed++;
          });
        }
      }

      setState(() {
        isIndexing = false;
      });

      images.sort((a, b) => a.name.compareTo(b.name));

      if (images.isNotEmpty) {
        try {
          tempDir =
              Directory('${dir.path}${Platform.pathSeparator}$tempFolder');
          await tempDir.create();
          await buildCache();
        } catch (e) {
          print('Error creating temp directory: ${e.toString()}');
        }
      }
    }
  }

  Future<void> addToList(FileSystemEntity e) async {
    print("adding to list " + e.path);
    if (e.path.endsWith(".ARW") || e.path.endsWith(".NEF")) {
      try {
        final file = File(e.path);
        final bytes = await file.readAsBytes();
        final exifData = await readExifFromBytes(bytes);

        // Default values for when EXIF data is not available
        final Map<String, dynamic> processedExif = {
          'Camera Model': 'Unknown',
          'Lens Model': 'Unknown',
          'Shooting Date': 'Unknown',
          'Exposure Time': 'Unknown',
          'Aperture': 'Unknown',
          'ISO': 'Unknown',
          'Focal Length': 'Unknown',
          'White Balance': 'Unknown',
          'Image Size': 'Unknown',
          'File Path': e.path,
        };

        // Map common EXIF tags to more readable names
        if (exifData != null) {
          if (exifData['Image Model'] != null) {
            processedExif['Camera Model'] = exifData['Image Model']!.printable;
          }
          if (exifData['EXIF LensModel'] != null) {
            processedExif['Lens Model'] = exifData['EXIF LensModel']!.printable;
          }
          if (exifData['EXIF DateTimeOriginal'] != null) {
            processedExif['Shooting Date'] =
                exifData['EXIF DateTimeOriginal']!.printable;
          }
          if (exifData['EXIF ExposureTime'] != null) {
            processedExif['Exposure Time'] =
                exifData['EXIF ExposureTime']!.printable;
          }
          if (exifData['EXIF FNumber'] != null) {
            // Parse the rational number format (e.g., "9/5" to 1.8)
            final String fnumberStr = exifData['EXIF FNumber']!.printable;
            try {
              final List<String> parts = fnumberStr.split('/');
              if (parts.length == 2) {
                final double numerator = double.parse(parts[0]);
                final double denominator = double.parse(parts[1]);
                final double fNumber = numerator / denominator;
                processedExif['Aperture'] = 'f/${fNumber.toStringAsFixed(1)}';
              } else {
                // Handle cases where it's just a single number
                processedExif['Aperture'] = 'f/$fnumberStr';
              }
            } catch (e) {
              processedExif['Aperture'] =
                  'f/$fnumberStr'; // Fallback to raw value
            }
          }
          if (exifData['EXIF ISOSpeedRatings'] != null) {
            processedExif['ISO'] =
                'ISO ${exifData['EXIF ISOSpeedRatings']!.printable}';
          }
          if (exifData['EXIF FocalLength'] != null) {
            processedExif['Focal Length'] =
                '${exifData['EXIF FocalLength']!.printable}mm';
          }
          if (exifData['EXIF WhiteBalance'] != null) {
            processedExif['White Balance'] =
                exifData['EXIF WhiteBalance']!.printable;
          }
          if (exifData['EXIF PixelXDimension'] != null &&
              exifData['EXIF PixelYDimension'] != null) {
            processedExif['Image Size'] =
                '${exifData['EXIF PixelXDimension']!.printable} x ${exifData['EXIF PixelYDimension']!.printable}';
          }
        }

        ImageData imageData = ImageData(
          name: e.path.split(Platform.pathSeparator).last,
          path: e.path,
          exifData: processedExif,
        );

        images.add(imageData);
      } catch (error) {
        print('Error processing EXIF data for ${e.path}: $error');
        // Add the image anyway, but with minimal EXIF data
        ImageData imageData = ImageData(
          name: e.path.split(Platform.pathSeparator).last,
          path: e.path,
          exifData: {
            'Error': 'Failed to read EXIF data',
            'File Path': e.path,
          },
        );
        images.add(imageData);
      } finally {
        print('${e.path} processed and added');
      }
    } else {
      print('${e.path} is not a supported image format');
    }
  }

  String getPreviewPath(String filename) {
    String path =
        '${dir.path}${Platform.pathSeparator}$tempFolder${Platform.pathSeparator}$filename.jpeg';
    return path;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _itemKeys.clear();
    super.dispose();
  }

  Future<void> saveSelectedPhotos() async {
    String? targetDir = await FilePicker.platform.getDirectoryPath();
    if (targetDir == null) return;

    int copied = 0;
    int total = images.where((img) => img.isChosen).length;

    setState(() {
      isProcessing = true;
      generated = 0;
    });

    try {
      for (var image in images) {
        if (image.isChosen) {
          File sourceFile = File(image.path);
          String fileName = image.name;
          String destinationPath =
              '$targetDir${Platform.pathSeparator}$fileName';

          await sourceFile.copy(destinationPath);

          setState(() {
            generated = ++copied;
          });
        }
      }
    } catch (e) {
      print('Error copying files: $e');
    } finally {
      setState(() {
        isProcessing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return KeyPressListener(
      repeatInterval: Duration(milliseconds: 150),
      onKeyPress: (KeyDownEvent event) {
        setState(() {
          if (event.physicalKey == PhysicalKeyboardKey.arrowRight)
            changeSelectedImageByHowMuch(1);
          else if (event.physicalKey == PhysicalKeyboardKey.arrowLeft)
            changeSelectedImageByHowMuch(-1);
          else if (event.physicalKey == PhysicalKeyboardKey.arrowUp)
            changeSelectedImageByHowMuch(-4);
          else if (event.physicalKey == PhysicalKeyboardKey.arrowDown)
            changeSelectedImageByHowMuch(4);
          else if (event.physicalKey == PhysicalKeyboardKey.shiftRight) {
            print("minus");
            images[lastClicked] = images[lastClicked].copyWith(
                isDeleted: !images[lastClicked].isDeleted, isChosen: false);
          } else if (event.physicalKey == PhysicalKeyboardKey.space) {
            images[lastClicked] = images[lastClicked].copyWith(
                isChosen: !images[lastClicked].isChosen, isDeleted: false);
          } else if (event.physicalKey == PhysicalKeyboardKey.keyE) {
            showErrorDialog(context, 'Simulated error');
          } else {
            print("dir: " + dir.path);
            print("tempDir: " + tempDir.toString());
            print("folderPath: " + dir.path);
            print("tempFolderName:" + tempFolder);
            print("isProcessing: " + isProcessing.toString());
            print("generated: " + generated.toString());
            print("bigPreview: " + bigPreview.toString());
            print("lastClicked: " + lastClicked.toString());
          }
          selected = 0;
          deleted = 0;
          images.forEach((ImageData a) {
            if (a.isChosen) selected++;
            if (a.isDeleted) deleted++;
          });
        });
        return KeyEventResult.handled;
      },
      child: Scaffold(
        body: Row(
          children: [
            Expanded(
              flex: 1,
              child: Container(
                color: Colors.black26,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    Container(
                      color: Colors.black45,
                      height: 60,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(15, 8, 15, 8),
                        child: Center(
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                  child: Text(
                                dir.path != Directory.current.path?dir.path:"",
                                overflow: TextOverflow.fade,
                                maxLines: 2,
                              )),
                              IconButton(
                                  onPressed: pickFolder,
                                  icon: Icon(Icons.folder)),
                              IconButton(
                                  onPressed: () => FocusManager
                                      .instance.primaryFocus
                                      ?.requestFocus(),
                                  icon: Icon(Icons.keyboard)),
                              IconButton(
                                  onPressed: () {
                                    print("save to file");
                                  },
                                  icon: Icon(Icons.save)),
                              ElevatedButton(
                                onPressed: selected>0?() async =>
                                    await saveSelectedPhotos():null,
                                child: Text('Export selected'),

                              )
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (dir.path != Directory.current)
                      Expanded(
                        child: images.isEmpty
                            ? Center(child: ElevatedButton(onPressed: pickFolder, child: Text("Select a folder")))
                            : GridView.builder(
                                primary: false,
                                controller: _scrollController,
                                padding: const EdgeInsets.all(8),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 4,
                                  crossAxisSpacing: 5,
                                  mainAxisSpacing: 5,
                                  childAspectRatio: 1,
                                ),
                                itemCount: images.length,
                                itemBuilder: (BuildContext context, int index) {
                                  final imageData = images[index];
                                  final previewPath =
                                      getPreviewPath(imageData.name);
                                  final previewFile = File(previewPath);

                                  return Container(
                                    key: getKeyForIndex(index),
                                    decoration: BoxDecoration(
                                        color: imageData.isDeleted
                                            ? Colors
                                                .transparent // Add visual feedback for deleted state
                                            : imageData.isChosen
                                                ? Colors.yellow
                                                : null,
                                        border: Border.all(
                                            width: 3,
                                            color: imageData.isSelected
                                                ? Colors
                                                    .red // Add visual feedback for deleted state
                                                : Colors.transparent)),
                                    child: InkWell(
                                      onTap: () {
                                        setState(() {
                                          changeSelectedImage(index);
                                        });
                                      },
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Expanded(
                                            flex: 4,
                                            child: Container(
                                              child: previewFile.existsSync()
                                                  ? Image.file(
                                                      opacity: imageData
                                                              .isDeleted
                                                          ? const AlwaysStoppedAnimation(
                                                              .5)
                                                          : null,
                                                      fit: BoxFit.fitWidth,
                                                      previewFile,
                                                      // Cache images to improve performance
                                                      cacheWidth:
                                                          200, // Adjust based on your needs
                                                      errorBuilder: (context,
                                                          error, stackTrace) {
                                                        return const Center(
                                                          child: Icon(
                                                              Icons.error,
                                                              color:
                                                                  Colors.red),
                                                        );
                                                      },
                                                    )
                                                  : const Center(
                                                      child:
                                                          CircularProgressIndicator(),
                                                    ),
                                            ),
                                          ),
                                          Expanded(
                                            flex: 1,
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 8),
                                              alignment: Alignment.center,
                                              child: Text(
                                                imageData.name,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                    fontSize: 12,
                                                    color: imageData.isDeleted
                                                        ? Colors
                                                            .grey // Add visual feedback for deleted state
                                                        : imageData.isChosen
                                                            ? Colors.black
                                                            : Colors.white),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      )
                    else
                      const Text('No folder selected'),
                    if (isIndexing || isProcessing)
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Column(
                          children: [
                            if (isIndexing) ...[
                              Text(
                                  "Indexing files ${indexed}/${totalFiles}..."),
                              LinearProgressIndicator(
                                value:
                                    totalFiles > 0 ? indexed / totalFiles : 0,
                              ),
                              SizedBox(height: 8),
                            ],
                            if (isProcessing) ...[
                              Text(
                                  "Processing thumbnails ${generated}/${images.length}..."),
                              LinearProgressIndicator(
                                value: images.isNotEmpty
                                    ? generated / images.length
                                    : 0,
                              ),
                            ],
                          ],
                        ),
                      ),
                    Container(
                      padding: EdgeInsets.fromLTRB(15, 0, 15, 0),
                      height: 40,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text("Selected: " + selected.toString()),
                          Text(images.length.toString()),
                          Text("Deleted: " + deleted.toString())
                        ],
                      ),
                    )
                  ],
                ),
              ),
            ),
            Expanded(
                flex: () {
                  final width = MediaQuery.of(context).size.width;
                  if (width > 1200) return 2;
                  return 1;
                }(),
                child: Stack(
                  children: [
                    Container(
                      padding: EdgeInsets.all(10),
                      child: Center(
                        child: bigPreview != null
                            ? bigPreview!.existsSync()
                                ? InteractiveViewer(
                                    trackpadScrollCausesScale: false,
                                    minScale: 1,
                                    maxScale: 4,
                                    child:
                                        Center(child: Image.file(bigPreview!)))
                                : Center(
                                    child: CircularProgressIndicator(),
                                  )
                            : Text("No folder selected"),
                      ),
                    ),
                    Align(
                      alignment: Alignment.topRight,
                      child: Container(
                        color: const Color.fromARGB(153, 0, 0, 0),
                        width: 300,
                        child: ExpansionTile(
                            title: Text(!images.isEmpty
                                ? images[lastClicked].name
                                : "none"),
                            subtitle: Text('Raw info'),
                            children: lastClicked < images.length
                                ? images[lastClicked]
                                    .exifData
                                    .entries
                                    .map((entry) => Container(
                                          decoration: BoxDecoration(
                                            border: Border(
                                              top: BorderSide(
                                                  color: const Color.fromARGB(135, 255, 255, 255)),
                                            ),
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.all(8.0),
                                            child: Align(
                                              alignment: Alignment.centerLeft,
                                              child: Row(
                                                children: [
                                                  Align(
                                                    alignment:
                                                        Alignment.topLeft,
                                                    child: Text(
                                                      "${entry.key}: ",
                                                      style: TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold),
                                                    ),
                                                  ),
                                                  Expanded(
                                                    child:
                                                        Text("${entry.value}"),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ))
                                    .toList()
                                : [ListTile(title: Text('No image'))]),
                      ),
                    ),
                  ],
                ))
          ],
        ),
      ),
    );
  }
}

//ListTile(title: Text('This is tile number 1')),