import 'dart:html';
import 'package:angular/angular.dart';
import 'package:angular_components/material_input/material_input.dart';
import 'package:angular_components/material_button/material_button.dart';
import 'package:angular_router/angular_router.dart';
import 'package:quiver/strings.dart';

import '../routes.dart';

@Component(
  selector: 'root',
  templateUrl: 'root.html',
  styleUrls: ['root.css'],
  directives: [materialInputDirectives, MaterialButtonComponent],
)
class RootComponent {
  final Router _router;
  RootComponent(this._router);

  String player = '';
  String gameId = '';
  String get _gameUrl => RoutePaths.game
      .toUrl(parameters: {gameIdParam: gameId, playerParam: player});

  String _errorMsg = '';
  String get errorMsg => _errorMsg;

  @ViewChild('playerInput')
  MaterialInputComponent playerInput;

  void onEnter() {
    _errorMsg = '';

    if (isBlank(gameId)) {
      _errorMsg = "Game id can't be blank";
      return;
    }
    if (isBlank(player)) {
      _errorMsg = "Username can't be blank";
      return;
    }

    _router.navigate(_gameUrl);
  }

  void onGameIdKeypress(KeyboardEvent e) {
    if (e.key == 'Enter') {
      playerInput.focus();
    }
  }

  void onPlayerKeypress(KeyboardEvent e) {
    if (e.key == 'Enter') {
      onEnter();
    }
  }
}
