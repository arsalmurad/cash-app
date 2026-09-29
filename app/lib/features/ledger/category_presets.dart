import 'package:flutter/material.dart';

/// One category seeded on first launch: a stable ID, a display name, and an
/// icon key resolved through [categoryIcon]. Seeding happens once (see
/// `LedgerController.initialize`) — after that, categories are ordinary
/// last-writer-wins state a user can rename or add to freely.
class CategoryPreset {
  const CategoryPreset({
    required this.id,
    required this.name,
    required this.iconKey,
  });

  final String id;
  final String name;
  final String iconKey;
}

const defaultCategoryPresets = [
  CategoryPreset(id: 'everyday', name: 'Everyday', iconKey: 'shopping_cart'),
  CategoryPreset(id: 'food', name: 'Food', iconKey: 'restaurant'),
  CategoryPreset(id: 'transport', name: 'Transport', iconKey: 'directions_car'),
  CategoryPreset(id: 'home', name: 'Home', iconKey: 'home'),
  CategoryPreset(id: 'income', name: 'Income', iconKey: 'attach_money'),
];

const _categoryIcons = <String, IconData>{
  'shopping_cart': Icons.shopping_cart_outlined,
  'restaurant': Icons.restaurant_outlined,
  'directions_car': Icons.directions_car_outlined,
  'home': Icons.home_outlined,
  'attach_money': Icons.attach_money_rounded,
  'shopping_bag': Icons.shopping_bag_outlined,
  'flight': Icons.flight_outlined,
  'fitness_center': Icons.fitness_center_outlined,
  'pets': Icons.pets_outlined,
  'school': Icons.school_outlined,
  'movie': Icons.movie_outlined,
  'local_hospital': Icons.local_hospital_outlined,
};

/// Every icon key a category can be created with, in a stable display order.
List<String> get availableCategoryIconKeys => _categoryIcons.keys.toList();

/// Resolves a category's stored icon key to an [IconData], falling back to a
/// generic label icon if the key is unrecognized (e.g. from a future app
/// version's icon set that this build doesn't know yet).
IconData categoryIcon(String iconKey) =>
    _categoryIcons[iconKey] ?? Icons.label_outline_rounded;
