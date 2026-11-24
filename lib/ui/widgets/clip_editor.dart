// 편집 창의 공개 API. 실제 구현은 lib/ui/editor/ 에 있다.
// 기존 import 경로(home_screen, clip_list, 시험)를 그대로 쓰게 다시 내보낸다.
export '../editor/clip_editor_dialog.dart'
    show showClipEditor, ClipEditorDialog, EditorExit;
export '../editor/edit_pieces.dart' show EditPiece, EditPieces;
export '../format.dart' show formatClock;
