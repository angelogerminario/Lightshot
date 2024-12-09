class ImageData {
  final String name;
  final String path;
  final Map<String, dynamic> exifData;
  bool isSelected;
  bool isChosen;
  bool isDeleted;

  ImageData({
    required this.name,
    required this.path,
    required this.exifData,
    this.isSelected = false,
    this.isChosen = false,
    this.isDeleted = false,
  });

  // Copy constructor for creating a new instance with modified values
  ImageData copyWith({
    String? name,
    String? path,
    Map<String, dynamic>? exifData,
    bool? isSelected,
    bool? isChosen,
    bool? isDeleted,
  }) {
    return ImageData(
      name: name ?? this.name,
      path: path ?? this.path,
      exifData: exifData ?? this.exifData,
      isSelected: isSelected ?? this.isSelected,
      isChosen: isChosen ?? this.isChosen,
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }
}
