import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

typedef StreamStateCallback = void Function(MediaStream stream);

class WebRTCJsonFactory {
  RTCIceCandidate createCandidate(Map<String, dynamic> json) =>
      RTCIceCandidate(json['candidate'], json['sdpMid'], json['sdpMLineIndex']);
  RTCSessionDescription createSessionDescription(Map<String, dynamic> json) =>
      RTCSessionDescription(json['sdp'], json['type']);
}

const configuration = {
  'iceServers': [
    {
      'urls': [
        'stun:stun1.l.google.com:19302',
        'stun:stun2.l.google.com:19302',
      ],
    },
  ],
};

class Signaling with WebRTCJsonFactory {
  String phone;
  RTCPeerConnection? peerConnection;
  MediaStream? localMediaStream;
  MediaStream? remoteMediaStream;
  String? call;
  StreamStateCallback? onAddRemoteStream;
  RTCVideoRenderer remoteRenderer;
  RTCVideoRenderer localRenderer;

  Signaling({
    required this.remoteRenderer,
    required this.localRenderer,
    required this.phone,
  });

  Future<void> setUpCall() async {
    await initPeerConnection();

    await addLocalTracksToPeer();
    await addLocalMediaStream();
    await addRemoteMediaStream();
    await createCallWithOffer();
    peerConnection?.onIceCandidate = (RTCIceCandidate candidate) async {
      var initiatorsRef = (await FirebaseFirestore.instance.collection('calls').where('phone', isEqualTo: phone).get())
          .docs
          .first
          .reference
          .collection('initiators');
      initiatorsRef.add(candidate.toMap());
    };
    waitCallRemoteDescription();
    waitConnectors();
  }

  Future<void> initPeerConnection() async {
    peerConnection = await createPeerConnection(configuration);
    addPeerConnectionCallbacks();
  }

  Future<void> createCallWithOffer() async {
    var callsRef = FirebaseFirestore.instance.collection('calls');
    RTCSessionDescription offer = await peerConnection!.createOffer();
    await peerConnection?.setLocalDescription(offer);
    Json call = {'offer': offer.toMap(), 'phone': phone};
    callsRef.doc().set(call);
  }

  void addPeerConnectionCallbacks() {
    peerConnection?.onTrack = (RTCTrackEvent event) {
      event.streams.first.getTracks().forEach((track) {
        remoteMediaStream?.addTrack(track);
      });
    };

    peerConnection?.onAddStream = (MediaStream stream) {
      onAddRemoteStream?.call(stream);
      remoteMediaStream = stream;
    };
  }

  void waitCallRemoteDescription() {
    var callsRef = FirebaseFirestore.instance.collection('calls');
    callsRef.doc().snapshots().listen((snapshot) async {
      if (snapshot.exists) {
        Json data = snapshot.data() as Json;
        if (peerConnection?.getRemoteDescription() != null && data['rsd'] != null) {
          var answer = createSessionDescription(data['rsd']);
          await peerConnection?.setRemoteDescription(answer);
        }
      }
    });
  }

  Future<void> waitConnectors() async {
    var connectorsRef = (await FirebaseFirestore.instance.collection('calls').where('phone', isEqualTo: phone).get())
        .docs
        .first
        .reference
        .collection('connectors');
    connectorsRef.snapshots().listen((snapshot) {
      for (var change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          Json data = change.doc.data() as Json;
          peerConnection!.addCandidate(createCandidate(data));
        }
      }
    });
  }

  Future<void> addLocalTracksToPeer() async {
    localMediaStream?.getTracks().forEach((track) {
      peerConnection?.addTrack(track, localMediaStream!);
    });
  }

  set localMediaSrcStream(MediaStream stream) {
    localRenderer.srcObject = stream;
    localMediaStream = stream;
  }

  Future<void> addLocalMediaStream() async {
    var stream = await navigator.mediaDevices.getUserMedia(MediaConstraints().json);
    localMediaSrcStream = stream;
  }

  Future<void> addRemoteMediaStream() async {
    remoteRenderer.srcObject = await createLocalMediaStream('key');
  }

  Future<void> acceptCall() async {
    print('0');
    var callRef = (await FirebaseFirestore.instance.collection('calls').where('phone', isEqualTo: phone).get())
        .docs
        .first
        .reference;
    var connectorsRef = callRef.collection('connectors');
    var initiatorsRef = callRef.collection('initiators');
    DocumentSnapshot callSnapshot = await callRef.get();
    print('1');
    if (callSnapshot.exists) {
      print('2');
      await initPeerConnection();
      peerConnection?.onIceCandidate = (RTCIceCandidate candidate) {
        print('ice');
        connectorsRef.add(candidate.toMap());
      };
      await addLocalTracksToPeer();
      await addLocalMediaStream();
      var callJson = callSnapshot.data() as Json;
      var offer = callJson['offer'];
      await peerConnection?.setRemoteDescription(createSessionDescription(offer));
      RTCSessionDescription answer = await peerConnection!.createAnswer();
      await peerConnection!.setLocalDescription(answer);
      Map<String, dynamic> callWithAnswer = {
        'rsd': {'type': answer.type, 'sdp': answer.sdp},
      };
      await callRef.update(callWithAnswer);
      initiatorsRef.snapshots().listen((snapshot) {
        for (DocumentChange document in snapshot.docChanges) {
          Json json = extractDocumentChangeData(document);
          peerConnection!.addCandidate(createCandidate(json));
        }
      });
    }
  }
}

typedef Json = Map<String, dynamic>;

class MediaConstraints {
  bool supportsVideo;
  bool supportsAudio;
  MediaConstraints({this.supportsVideo = true, this.supportsAudio = true});
  Json get json => {'video': supportsVideo, 'audio': supportsAudio};
}

class CallsCollection {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  CollectionReference get ref => _firestore.collection('calls');
}

Map<String, dynamic> extractDocumentChangeData(DocumentChange document) => document.doc.data() as Map<String, dynamic>;
