// Both headers are generated inside Darterfly, including the local TD edit.
enum class Attribute {
#define GET_ATTR_ENUM
#include "Attributes.inc"
};
enum class Declaration {
#define DECL(Type, Base) Type,
#include "DeclNodes.inc"
};
extern int archive_value();
int main() {
  static_assert(static_cast<int>(Attribute::DarterflyWorld) > 0);
  static_assert(static_cast<int>(Attribute::AlwaysInline) > 0);
  static_assert(Declaration::Function != Declaration::TranslationUnit);
  return 35 + archive_value();
}
