/*
 * auiosnd.c -I/O unit Media plugin for Linphone-
 *
 *
 * Copyright (C) 2009  Belledonne Comunications, Grenoble, France
 *
 *  This program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2 of the License, or
 *  (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU Library General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 */

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVAudioSession.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSString.h>

#import "mediastreamer2/mssndcard.h"
#import "mediastreamer2/msfilter.h"
#import "mediastreamer2/msticker.h"
#include <bctoolbox/param_string.h>

static const int flowControlInterval = 5000; // ms
static const int flowControlThreshold = 40; // ms

/*                          -------------------------
							| i                   o |
-- BUS 1 -- from mic -->	| n    REMOTE I/O     u | -- BUS 1 -- to app -->
							| p      AUDIO        t |
-- BUS 0 -- from app -->	| u       UNIT        p | -- BUS 0 -- to speaker -->
							| t                   u |
							|                     t |
							-------------------------
 */

static AudioUnitElement inputBus = 1;
static AudioUnitElement outputBus = 0;

static const char *audio_unit_format_error (OSStatus error) {
	switch (error) {
		case kAudioUnitErr_InvalidProperty: return "kAudioUnitErr_InvalidProperty";
		case kAudioUnitErr_InvalidParameter: return "kAudioUnitErr_InvalidParameter";
		case kAudioUnitErr_InvalidElement: return "kAudioUnitErr_InvalidElement";
		case kAudioUnitErr_NoConnection: return "kAudioUnitErr_NoConnection";
		case kAudioUnitErr_FailedInitialization: return "kAudioUnitErr_FailedInitialization";
		case kAudioUnitErr_TooManyFramesToProcess: return "kAudioUnitErr_TooManyFramesToProcess";
		case kAudioUnitErr_InvalidFile: return "kAudioUnitErr_InvalidFile";
		case kAudioUnitErr_UnknownFileType: return "kAudioUnitErr_UnknownFileType";
		case kAudioUnitErr_FileNotSpecified: return "kAudioUnitErr_FileNotSpecified";
		case kAudioUnitErr_FormatNotSupported: return "kAudioUnitErr_FormatNotSupported";
		case kAudioUnitErr_Uninitialized: return "kAudioUnitErr_Uninitialized";
		case kAudioUnitErr_InvalidScope: return "kAudioUnitErr_InvalidScope";
		case kAudioUnitErr_PropertyNotWritable: return "kAudioUnitErr_PropertyNotWritable";
		case kAudioUnitErr_CannotDoInCurrentContext: return "kAudioUnitErr_CannotDoInCurrentContext";
		case kAudioUnitErr_InvalidPropertyValue: return "kAudioUnitErr_InvalidPropertyValue";
		case kAudioUnitErr_PropertyNotInUse: return "kAudioUnitErr_PropertyNotInUse";
		case kAudioUnitErr_Initialized: return "kAudioUnitErr_Initialized";
		case kAudioUnitErr_InvalidOfflineRender: return "kAudioUnitErr_InvalidOfflineRender";
		case kAudioUnitErr_Unauthorized: return "kAudioUnitErr_Unauthorized";
		default: {
			ms_error ("Cannot start audioUnit because [%c%c%c%c]"
						  ,((char*)&error)[3]
						  ,((char*)&error)[2]
						  ,((char*)&error)[1]
						  ,((char*)&error)[0]);
			return "unknown error";
		}
	}

}

#define check_au_session_result(au,method) \
if (au!=AVAudioSessionErrorInsufficientPriority && au!=0) ms_error("AudioSession error for %s: ret=%i (%s:%d)",method, au, __FILE__, __LINE__)

#define check_au_unit_result(au,method) \
if (au!=0) ms_error("AudioUnit error for %s: ret=%s (%li) (%s:%d)",method, audio_unit_format_error(au), (long)au, __FILE__, __LINE__)

#define check_session_call(call)   do { OSStatus res = (call); check_au_session_result(res, #call); } while(0)
#define check_audiounit_call(call) do { OSStatus res = (call); check_au_unit_result(res, #call); } while(0)

static const char * SCM_PARAM_FAST = "FAST";
static const char * SCM_PARAM_NOVOICEPROC = "NOVOICEPROC";
static const char * SCM_PARAM_TESTER = "TESTER";
static const char * SCM_PARAM_RINGER = "RINGER";
static const char* SPEAKER_CARD_NAME = "Speaker";

static MSFilter *ms_au_read_new(MSSndCard *card);
static MSFilter *ms_au_write_new(MSSndCard *card);

typedef struct au_filter_read_data au_filter_read_data_t;
typedef struct au_filter_write_data au_filter_write_data_t;

typedef enum _MSAudioUnitState{
	MSAudioUnitNotCreated,
	MSAudioUnitCreated,
	MSAudioUnitConfigured,
	MSAudioUnitStarted
} MSAudioUnitState;

@interface AudioUnitHolder : NSObject

@property AudioUnit	audio_unit;
@property MSAudioUnitState audio_unit_state;
@property unsigned int	rate;
@property unsigned int	bits;
@property unsigned int	nchannels;
@property uint64_t last_failed_iounit_start_time;
@property MSFilter* read_filter;
@property MSFilter* write_filter;
@property MSSndCard* ms_snd_card;
@property bool_t audio_session_configured;
@property bool_t read_started;
@property bool_t write_started;
@property bool_t will_be_used;
@property bool_t audio_session_activated;
@property bool_t callkit_enabled;
@property bool_t mic_enabled;

+(AudioUnitHolder *)sharedInstance;
- (id)init;
-(void)create_audio_unit;
-(void)configure_audio_unit;
-(bool_t)start_audio_unit:(uint64_t) time;
-(void)stop_audio_unit_with_param:(bool_t) isConfigured;
-(void)stop_audio_unit;
-(void)destroy_audio_unit;
-(void)mutex_lock;
-(void)mutex_unlock;

-(void) check_audio_unit_is_up;
-(void) configure_audio_session;
@end

typedef struct au_filter_base {
	int muted;
} au_filter_base_t;

struct au_filter_read_data{
	au_filter_base_t base;
	ms_mutex_t	mutex;
	queue_t		rq;
	AudioTimeStamp readTimeStamp;
	unsigned int n_lost_frame;
	MSTickerSynchronizer *ticker_synchronizer;
	uint64_t read_samples;
};

struct au_filter_write_data{
	au_filter_base_t base;
	ms_mutex_t mutex;
	MSFlowControlledBufferizer *bufferizer;
	unsigned int n_lost_frame;
};
 
/*
 mediastreamer2 function
 */

static void au_set_level(MSSndCard *card, MSSndCardMixerElem e, int percent) {}

static int au_get_level(MSSndCard *card, MSSndCardMixerElem e) {
	return 0;
}

static void au_set_source(MSSndCard *card, MSSndCardCapture source) {}

static OSStatus au_render_cb (
							  void                        *inRefCon,
							  AudioUnitRenderActionFlags  *ioActionFlags,
							  const AudioTimeStamp        *inTimeStamp,
							  UInt32                      inBusNumber,
							  UInt32                      inNumberFrames,
							  AudioBufferList             *ioData
							  );
	
static OSStatus au_read_cb (
							  void                        *inRefCon,
							  AudioUnitRenderActionFlags  *ioActionFlags,
							  const AudioTimeStamp        *inTimeStamp,
							  UInt32                      inBusNumber,
							  UInt32                      inNumberFrames,
							  AudioBufferList             *ioData
);

static OSStatus au_write_cb (
							  void                        *inRefCon,
							  AudioUnitRenderActionFlags  *ioActionFlags,
							  const AudioTimeStamp        *inTimeStamp,
							  UInt32                      inBusNumber,
							  UInt32                      inNumberFrames,
							  AudioBufferList             *ioData
							 );

/**
 * AudioUnit helper functions, to associate the AudioUnit with the MSSndCard object used by mediastreamer2.
 */

@implementation AudioUnitHolder

ms_mutex_t mutex;

+ (AudioUnitHolder *)sharedInstance {
	static AudioUnitHolder *sharedInstance = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		sharedInstance = [[self alloc] init];
	});
	return sharedInstance;
}

- (id)init {
	if (self = [super init]) {
	 ms_debug("au_init");
	 _bits=16;
	 _rate=AVAudioSession.sharedInstance.sampleRate; /*not set*/
	 _nchannels=1;
	 _ms_snd_card=NULL;
	 _will_be_used = FALSE;
	 ms_mutex_init(&mutex,NULL);
	 _mic_enabled = TRUE;
	}
	return self;
}

-(void)create_audio_unit {
	AudioComponentDescription au_description;
	AudioComponent foundComponent;

	if (_audio_unit != NULL) return;
	if (_ms_snd_card == NULL) {
		ms_error("create_audio_unit(): not created because no associated ms_snd_card was found");
		return;
	}
	bool_t noVoiceProc = bctbx_param_string_get_bool_value(_ms_snd_card->sndcardmanager->paramString, SCM_PARAM_NOVOICEPROC) || _ms_snd_card->streamType == MS_SND_CARD_STREAM_MEDIA;
	OSType subtype = noVoiceProc ? kAudioUnitSubType_RemoteIO : kAudioUnitSubType_VoiceProcessingIO;

	au_description.componentType          = kAudioUnitType_Output;
	au_description.componentSubType       = subtype;
	au_description.componentManufacturer  = kAudioUnitManufacturer_Apple;
	au_description.componentFlags         = 0;
	au_description.componentFlagsMask     = 0;

	foundComponent = AudioComponentFindNext (NULL,&au_description);

	check_audiounit_call( AudioComponentInstanceNew(foundComponent, &_audio_unit) );

	//Always configure readcb
	AURenderCallbackStruct renderCallbackStruct;
	renderCallbackStruct.inputProc       = au_read_cb;
	//renderCallbackStruct.inputProcRefCon = au_holder;
	check_audiounit_call(AudioUnitSetProperty (
											   _audio_unit,
											   kAudioOutputUnitProperty_SetInputCallback,
											   kAudioUnitScope_Input,
											   outputBus,
											   &renderCallbackStruct,
											   sizeof (renderCallbackStruct)
											   ));

	if (_audio_unit) {
		ms_message("AudioUnit created with type %s.", subtype==kAudioUnitSubType_RemoteIO ? "kAudioUnitSubType_RemoteIO" : "kAudioUnitSubType_VoiceProcessingIO" );
		_audio_unit_state =MSAudioUnitCreated;
	}
	return;
}

-(void)configure_audio_unit {
	OSStatus auresult;
	
	if (_audio_unit_state != MSAudioUnitCreated){
		ms_error("configure_audio_unit(): not created, in state %i", _audio_unit_state);
		return;
	}
	uint64_t time_start, time_end;
	
	time_start = ortp_get_cur_time_ms();
	ms_message("configure_audio_unit() now called.");
	
	AudioStreamBasicDescription audioFormat;
	/*card sampling rate is fixed at that time*/
	audioFormat.mSampleRate			= _rate;
	audioFormat.mFormatID			= kAudioFormatLinearPCM;
	audioFormat.mFormatFlags		= kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
	audioFormat.mFramesPerPacket	= 1;
	audioFormat.mChannelsPerFrame	= _nchannels;
	audioFormat.mBitsPerChannel		= _bits;
	audioFormat.mBytesPerPacket		= _bits / 8;
	audioFormat.mBytesPerFrame		= _nchannels * _bits / 8;

	UInt32 doNotSetProperty    = 0;
	UInt32 doSetProperty    = 1;

	//enable speaker output
	auresult =AudioUnitSetProperty (
									_audio_unit,
									kAudioOutputUnitProperty_EnableIO,
									kAudioUnitScope_Output ,
									outputBus,
									&doSetProperty,
									sizeof (doSetProperty)
									);
	check_au_unit_result(auresult,"kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Output");

	/*enable mic for scheduling render call back, why ?*/
	auresult=AudioUnitSetProperty (/*enable mic input*/
								   _audio_unit,
								   kAudioOutputUnitProperty_EnableIO,
								   kAudioUnitScope_Input ,
								   inputBus,
								   _mic_enabled ? &doSetProperty : &doNotSetProperty,
								   sizeof (_mic_enabled ? doSetProperty : doNotSetProperty)
								   );
	
	check_au_unit_result(auresult,"kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input");
	auresult=AudioUnitSetProperty (
								   _audio_unit,
								   kAudioUnitProperty_StreamFormat,
								   kAudioUnitScope_Output,
								   inputBus,
								   &audioFormat,
								   sizeof (audioFormat)
								   );
	check_au_unit_result(auresult,"kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output");
	/*end of: enable mic for scheduling render call back, why ?*/
	
	//setup stream format
	auresult=AudioUnitSetProperty (
								   _audio_unit,
								   kAudioUnitProperty_StreamFormat,
								   kAudioUnitScope_Input,
								   outputBus,
								   &audioFormat,
								   sizeof (audioFormat)
								   );
	check_au_unit_result(auresult,"kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input");

	//disable unit buffer allocation
	auresult=AudioUnitSetProperty (
								   _audio_unit,
								   kAudioUnitProperty_ShouldAllocateBuffer,
								   kAudioUnitScope_Output,
								   outputBus,
								   &doNotSetProperty,
								   sizeof (doNotSetProperty)
								   );
	check_au_unit_result(auresult,"kAudioUnitProperty_ShouldAllocateBuffer,kAudioUnitScope_Output");
	AURenderCallbackStruct renderCallbackStruct;
	renderCallbackStruct.inputProc       = au_write_cb;
	//renderCallbackStruct.inputProcRefCon = au_holder;

	auresult=AudioUnitSetProperty (
								   _audio_unit,
								   kAudioUnitProperty_SetRenderCallback,
								   kAudioUnitScope_Input,
								   outputBus,
								   &renderCallbackStruct,
								   sizeof (renderCallbackStruct)
								   );
	check_au_unit_result(auresult,"kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input");
	time_end = ortp_get_cur_time_ms();
	ms_message("configure_audio_unit() took %i ms.", (int)(time_end - time_start));
	_audio_unit_state=MSAudioUnitConfigured;
}

-(bool_t)start_audio_unit: (uint64_t) time {
	
	if (_audio_unit_state != MSAudioUnitConfigured){
		ms_error("start_audio_unit(): state is %i", _audio_unit_state);
		return FALSE;
	}
	uint64_t time_start, time_end;
	
	
	if (_last_failed_iounit_start_time == 0 || (time - _last_failed_iounit_start_time)>100) {
		time_start = ortp_get_cur_time_ms();
		ms_message("start_audio_unit(): about to start audio unit.");
		check_audiounit_call(AudioUnitInitialize(_audio_unit));
		
		Float64 delay;
		UInt32 delaySize = sizeof(delay);
		check_audiounit_call(AudioUnitGetProperty(_audio_unit
									  ,kAudioUnitProperty_Latency
									  , kAudioUnitScope_Global
									  , 0
									  , &delay
									  , &delaySize));

		UInt32 quality;
		UInt32 qualitySize = sizeof(quality);
		check_audiounit_call(AudioUnitGetProperty(_audio_unit
									  ,kAudioUnitProperty_RenderQuality
									  , kAudioUnitScope_Global
									  , 0
									  , &quality
									  , &qualitySize));
		ms_message("I/O unit latency [%f], quality [%u]",delay,(unsigned)quality);
		AVAudioSession *audioSession = [AVAudioSession sharedInstance];
		Float32 hwoutputlatency = audioSession.outputLatency;

		Float32 hwinputlatency = audioSession.inputLatency;

		Float32 hwiobuf = audioSession.IOBufferDuration;

		Float64 hwsamplerate = audioSession.sampleRate;

		OSStatus auresult;
		check_audiounit_call( (auresult = AudioOutputUnitStart(_audio_unit)) );
		if (auresult == 0){
			_audio_unit_state = MSAudioUnitStarted;
		}
		if (_audio_unit_state != MSAudioUnitStarted) {
			ms_message("AudioUnit could not be started, current hw output latency [%f] input [%f] iobuf[%f] hw sample rate [%f]",hwoutputlatency,hwinputlatency,hwiobuf,hwsamplerate);
			_last_failed_iounit_start_time = time;
		} else {
			ms_message("AudioUnit started, current hw output latency [%f] input [%f] iobuf[%f] hw sample rate [%f]",hwoutputlatency,hwinputlatency,hwiobuf,hwsamplerate);
			_last_failed_iounit_start_time = 0;
		}
		time_end = ortp_get_cur_time_ms();
		ms_message("start_audio_unit() took %i ms.", (int)(time_end - time_start));
	}
	return (_audio_unit_state == MSAudioUnitStarted);
}

-(void)stop_audio_unit_with_param: (bool_t) isConfigured {
	if (_audio_unit_state == MSAudioUnitStarted || _audio_unit_state == MSAudioUnitConfigured) {
		check_audiounit_call( AudioOutputUnitStop(_audio_unit) );
		ms_message("AudioUnit stopped");
		_audio_session_configured = isConfigured;
		check_audiounit_call( AudioUnitUninitialize(_audio_unit) );
		_audio_unit_state = MSAudioUnitCreated;
	}
}

-(void)stop_audio_unit {
	[self stop_audio_unit_with_param:FALSE];
}

-(void)destroy_audio_unit {
	[self stop_audio_unit];
	
	if (_audio_unit) {
		AudioComponentInstanceDispose (_audio_unit);
		_audio_unit = NULL;
		
		if ( !bctbx_param_string_get_bool_value(_ms_snd_card->sndcardmanager->paramString, SCM_PARAM_FAST) ) {
			NSError *err = nil;;
			[[AVAudioSession sharedInstance] setActive:FALSE withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&err];
			if(err) ms_error("Unable to activate audio session because : %s", [err localizedDescription].UTF8String);
			err = nil;
		}
		ms_message("AudioUnit destroyed");
		_audio_unit_state = MSAudioUnitNotCreated;
	}
}

-(void)mutex_lock {
	ms_mutex_lock(&mutex);
}
-(void)mutex_unlock {
	ms_mutex_unlock(&mutex);
}

-(void) configure_audio_session {
	NSError *err = nil;;
	//UInt32 audioCategorySize=sizeof(audioCategory);
	AVAudioSession *audioSession = [AVAudioSession sharedInstance];

		if (_audio_unit_state == MSAudioUnitStarted){
		ms_message("configure_audio_session(): AudioUnit is already started, skipping this process.");
		return;
	}

	if ( !bctbx_param_string_get_bool_value(_ms_snd_card->sndcardmanager->paramString, SCM_PARAM_FAST) ) {
		/*check that category wasn't changed*/
		NSString *currentCategory = audioSession.category;
		NSString *newCategory = AVAudioSessionCategoryPlayAndRecord;
		
		if (_ms_snd_card->streamType == MS_SND_CARD_STREAM_MEDIA){
			newCategory = AVAudioSessionCategoryPlayback;
		}else if (bctbx_param_string_get_bool_value(_ms_snd_card->sndcardmanager->paramString, SCM_PARAM_RINGER) ){
			newCategory = AVAudioSessionCategoryAmbient;
		}

		if (currentCategory != newCategory){
			_audio_session_configured = FALSE;
		}

		if (!_audio_session_configured) {
			uint64_t time_start, time_end;
			
			time_start = ortp_get_cur_time_ms();
			if (newCategory != AVAudioSessionCategoryPlayAndRecord) {
				ms_message("Configuring audio session for playback");
				[audioSession setCategory:newCategory
									error:&err];
				if (err){
					ms_error("Unable to change audio session category because : %s", [err localizedDescription].UTF8String);
					err = nil;
				}
				[audioSession setMode:AVAudioSessionModeDefault error:&err];
				if(err){
					ms_error("Unable to change audio session mode because : %s", [err localizedDescription].UTF8String);
					err = nil;
				}
			} else {
				ms_message("Configuring audio session for playback/record");
		
				[audioSession   setCategory:AVAudioSessionCategoryPlayAndRecord
						withOptions:AVAudioSessionCategoryOptionAllowBluetooth| AVAudioSessionCategoryOptionAllowBluetoothA2DP
							  error:&err];
				if (err) {
					ms_error("Unable to change audio category because : %s", [err localizedDescription].UTF8String);
					err = nil;
				}
				[audioSession setMode:AVAudioSessionModeVoiceChat error:&err];
				if (err) {
					ms_error("Unable to change audio mode because : %s", [err localizedDescription].UTF8String);
					err = nil;
				}
			}
			double sampleRate = 48000; /*let's target the highest sample rate*/
			[audioSession setPreferredSampleRate:sampleRate error:&err];
			if (err) {
				ms_error("Unable to change preferred sample rate because : %s", [err localizedDescription].UTF8String);
				err = nil;
			}
			/*
			According to QA1631, it is not safe to request a prefered I/O buffer duration or sample rate while
			the session is active.
			However, until the session is active, we don't know what the actual sampleRate will be.
			As a result the following code cannot be used. What was it for ? If put it in "if 0" in doubt.
			*/
#if 0
			Float32 preferredBufferSize;
			switch (card->rate) {
				case 11025:
				case 22050:
					preferredBufferSize= .020;
					break;
				default:
					preferredBufferSize= .015;
			}
			[audioSession setPreferredIOBufferDuration:(NSTimeInterval)preferredBufferSize
								   error:&err];
								   if(err) ms_error("Unable to change IO buffer duration because : %s", [err localizedDescription].UTF8String);
								   err = nil;

#endif
			[audioSession setActive:TRUE error:&err];
			if(err){
				ms_error("Unable to activate audio session because : %s", [err localizedDescription].UTF8String);
				err = nil;
			}
			time_end = ortp_get_cur_time_ms();
			ms_message("MSAURead/MSAUWrite: configureAudioSession() took %i ms.", (int)(time_end - time_start));
			_audio_session_configured = TRUE;
		} else {
			ms_message("Audio session already correctly configured.");
		}
		
	} else {
		ms_message("Fast iounit mode, audio session configuration must be done at application level.");
	}
	/*now that the AudioSession is configured, take the audioSession's sampleRate*/
	_rate = (int)[audioSession sampleRate];
	ms_message("MSAURead/MSAUWrite: AVAudioSession is configured at sample rate %i.", _rate);
}


-(void) check_audio_unit_is_up {
	[self configure_audio_session];
	if (_audio_unit_state == MSAudioUnitNotCreated){
		[self create_audio_unit];
	}
	if (_audio_unit_state == MSAudioUnitCreated){
		[self configure_audio_unit];
	}
	if (_audio_session_activated && _audio_unit_state == MSAudioUnitConfigured){
		[self start_audio_unit:0];
	}
	if (_audio_unit_state == MSAudioUnitStarted){
		ms_message("check_audio_unit_is_up(): audio unit is started.");
	}
}
@end

/* the interruption listener is not reliable, it can be overriden by other parts of the application */
/* as a result, we do nothing with it*/
static void au_interruption_listener (void *inClientData, UInt32 inInterruptionState) {}

static void au_init(MSSndCard *card){
	ms_debug("au_init");
	card->preferred_sample_rate=44100;
	card->capabilities|=MS_SND_CARD_CAP_BUILTIN_ECHO_CANCELLER|MS_SND_CARD_CAP_IS_SLOW;
}

static void au_uninit(MSSndCard *card){
	AudioUnitHolder *au_holder = [AudioUnitHolder sharedInstance];
	if ([au_holder ms_snd_card] == card)
	{
		[au_holder stop_audio_unit];
		[au_holder destroy_audio_unit];
	}
}

static void check_unused(){
	AudioUnitHolder *au_holder = [AudioUnitHolder sharedInstance];
	if ([au_holder audio_unit_state] == MSAudioUnitNotCreated || [au_holder read_filter] || [au_holder write_filter])
		return;
	
	if ( ([au_holder ms_snd_card] != NULL && bctbx_param_string_get_bool_value([au_holder ms_snd_card]->sndcardmanager->paramString, SCM_PARAM_TESTER)) || ![au_holder will_be_used] ) {
		[au_holder stop_audio_unit];
		[au_holder destroy_audio_unit];
	}
}

static void au_usage_hint(MSSndCard *card, bool_t used){
	[[AudioUnitHolder sharedInstance] setWill_be_used:used];
	check_unused();
}

static void au_detect(MSSndCardManager *m);
static MSSndCard *au_duplicate(MSSndCard *obj);

static void au_audio_route_changed(MSSndCard *obj) {
	AudioUnitHolder *au_holder = [AudioUnitHolder sharedInstance];
	//au_card_t *d = (au_card_t*)obj->data;
	unsigned int rate = (int)[[AVAudioSession sharedInstance] sampleRate];
	if (rate >= [au_holder rate]) {
		return;
	}

	[au_holder stop_audio_unit];
	[au_holder setRate:rate];
	ms_message("MSAURead/MSAUWrite: AVAudioSession is configured from at sample rate %i.", [au_holder rate]);
	[au_holder configure_audio_unit];
	[au_holder start_audio_unit:0];

	if ([au_holder write_filter]) {
		au_filter_write_data_t *ft=(au_filter_write_data_t*)[au_holder write_filter]->data;
		ms_flow_controlled_bufferizer_set_samplerate(ft->bufferizer, rate);
		ms_filter_notify_no_arg([au_holder write_filter], MS_FILTER_OUTPUT_FMT_CHANGED);
	}
	if ([au_holder read_filter]) {
		ms_filter_notify_no_arg([au_holder read_filter], MS_FILTER_OUTPUT_FMT_CHANGED);
	}
}

static void au_audio_session_activated(MSSndCard *obj, bool_t actived) {
	AudioUnitHolder *au_holder = [AudioUnitHolder sharedInstance];
	[au_holder setAudio_session_activated:actived];
	if (actived && [au_holder audio_unit_state] == MSAudioUnitConfigured){
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH,0), ^{
			[[AudioUnitHolder sharedInstance] start_audio_unit:0];});
	}else if (!actived && [au_holder audio_unit_state] == MSAudioUnitStarted) {
		[au_holder stop_audio_unit_with_param:TRUE];
		[au_holder  configure_audio_unit];
	}
}

static void au_callkit_enabled(MSSndCard *obj, bool_t enabled) {
	AudioUnitHolder *au_holder = [AudioUnitHolder sharedInstance];
	[au_holder setCallkit_enabled:enabled];
	if (!enabled || TARGET_IPHONE_SIMULATOR) {
		// There is only callKit can notify audio session is activated or not.
		// So set audio session always activated when callkit is disabled.
		[au_holder setAudio_session_activated:true];
	}
}

MSSndCardDesc au_card_desc={
.driver_type="AU",
.detect=au_detect,
.init=au_init,
.set_level=au_set_level,
.get_level=au_get_level,
.set_capture=au_set_source,
.set_control=NULL,
.get_control=NULL,
.create_reader=ms_au_read_new,
.create_writer=ms_au_write_new,
.uninit=au_uninit,
.duplicate=au_duplicate,
.usage_hint=au_usage_hint,
.audio_session_activated=au_audio_session_activated,
.callkit_enabled=au_callkit_enabled,
.audio_route_changed=au_audio_route_changed
};

static MSSndCard *au_duplicate(MSSndCard *obj){
	MSSndCard *card=ms_snd_card_new_with_name(&au_card_desc,obj->name);
	card->device_type = obj->device_type;
	return card;
}

static MSSndCard *au_card_new(const char* name){
	MSSndCard *card=ms_snd_card_new_with_name(&au_card_desc,name);
	return card;
}

MSSndCardDeviceType deduceDeviceTypeFromInputAudioPortType(AVAudioSessionPort inputPort)
{
	if ([inputPort isEqualToString:(AVAudioSessionPortBuiltInMic)])
	{
		return MS_SND_CARD_DEVICE_TYPE_MICROPHONE;
	}
	else if ([inputPort isEqualToString:(AVAudioSessionPortBluetoothHFP)])
	{
		return MS_SND_CARD_DEVICE_TYPE_BLUETOOTH;
	}
	else if ([inputPort isEqualToString:(AVAudioSessionPortHeadsetMic)])
	{
		return MS_SND_CARD_DEVICE_TYPE_HEADPHONES;
	}
	
	return MS_SND_CARD_DEVICE_TYPE_UNKNOWN;
}

static void au_detect(MSSndCardManager *m){
	ms_debug("au_detect");
	
	NSArray *inputs = [[AVAudioSession sharedInstance] availableInputs];
	
	for (AVAudioSessionPortDescription *input in inputs) {
		MSSndCard *card = au_card_new(ms_strdup_printf("%s", [input.portName UTF8String]));
		card->device_type = deduceDeviceTypeFromInputAudioPortType(input.portType);
		ms_snd_card_manager_add_card(m, card);
		ms_message("au_detect, creating snd card %p", card);
	}
	
	MSSndCard *speakerCard = au_card_new(SPEAKER_CARD_NAME);
	speakerCard->device_type = MS_SND_CARD_DEVICE_TYPE_SPEAKER;
	ms_snd_card_manager_add_card(m, speakerCard);
	ms_message("au_detect -- speaker snd card %p", speakerCard);
}

/********************write cb only used for write operation******************/
static OSStatus au_read_cb (
							  void                        *inRefCon,
							  AudioUnitRenderActionFlags  *ioActionFlags,
							  const AudioTimeStamp        *inTimeStamp,
							  UInt32                      inBusNumber,
							  UInt32                      inNumberFrames,
							  AudioBufferList             *ioData
)
{
	AudioUnitHolder *au_holder = [AudioUnitHolder sharedInstance];

	[au_holder mutex_lock];
	if (![au_holder read_filter]) {
		//just return from now;
		[au_holder mutex_unlock];
		return 0;
	}
	au_filter_read_data_t *d = [au_holder read_filter]->data;
	if (d->readTimeStamp.mSampleTime <0) {
		d->readTimeStamp=*inTimeStamp;
	}
	OSStatus err=0;
	mblk_t * rm=NULL;
	AudioBufferList readAudioBufferList;
	readAudioBufferList.mBuffers[0].mDataByteSize=inNumberFrames * [au_holder bits]/8;
	readAudioBufferList.mNumberBuffers=1;
	readAudioBufferList.mBuffers[0].mNumberChannels= [au_holder nchannels];

	if ([au_holder read_started]) {
		rm=allocb(readAudioBufferList.mBuffers[0].mDataByteSize,0);
		readAudioBufferList.mBuffers[0].mData=rm->b_wptr;
		err = AudioUnitRender([au_holder audio_unit], ioActionFlags, &d->readTimeStamp, inBusNumber,inNumberFrames, &readAudioBufferList);
		if (err == 0) {
			rm->b_wptr += readAudioBufferList.mBuffers[0].mDataByteSize;
			ms_mutex_lock(&d->mutex);
			putq(&d->rq,rm);
			ms_mutex_unlock(&d->mutex);
			d->readTimeStamp.mSampleTime+=readAudioBufferList.mBuffers[0].mDataByteSize/([au_holder bits]/2);
		} else {
			check_au_unit_result(err, "AudioUnitRender");
			freeb(rm);
		}
	}
	[au_holder mutex_unlock];
	return err;
}

static OSStatus au_write_cb (
							  void                        *inRefCon,
							  AudioUnitRenderActionFlags  *ioActionFlags,
							  const AudioTimeStamp        *inTimeStamp,
							  UInt32                      inBusNumber,
							  UInt32                      inNumberFrames,
							  AudioBufferList             *ioData
							 ) {
	ms_debug("render cb");
	AudioUnitHolder *au_holder = [AudioUnitHolder sharedInstance];
	
	ioData->mBuffers[0].mDataByteSize=inNumberFrames*[au_holder bits]/8;
	ioData->mNumberBuffers=1;
	
	[au_holder mutex_lock];
	if(![au_holder write_filter]){
		[au_holder mutex_unlock];
		memset(ioData->mBuffers[0].mData, 0,ioData->mBuffers[0].mDataByteSize);
		return 0;
	}

	au_filter_write_data_t *d = [au_holder write_filter]->data;
	unsigned int size;
	ms_mutex_lock(&d->mutex);
	size = inNumberFrames*[au_holder bits]/8;
	if (ms_flow_controlled_bufferizer_get_avail(d->bufferizer) >= size) {
		ms_flow_controlled_bufferizer_read(d->bufferizer, ioData->mBuffers[0].mData, size);
	} else {
		//writing silence;
		memset(ioData->mBuffers[0].mData, 0,ioData->mBuffers[0].mDataByteSize);
		ms_debug("nothing to write, pushing silences,  framezize is %u bytes mDataByteSize %u"
				 ,inNumberFrames * [au_holder bits]/8
				 ,(unsigned int)ioData->mBuffers[0].mDataByteSize);
	}
	ms_mutex_unlock(&d->mutex);
	[au_holder mutex_unlock];
	return 0;
}


/***********************************read function********************/

static void au_read_preprocess(MSFilter *f){
	AudioUnitHolder *au_holder = [AudioUnitHolder sharedInstance];
	au_filter_read_data_t *d= (au_filter_read_data_t*)f->data;

	[au_holder check_audio_unit_is_up];
	d->ticker_synchronizer = ms_ticker_synchronizer_new();
	ms_ticker_set_synchronizer(f->ticker, d->ticker_synchronizer);
	[au_holder setRead_started:TRUE];
}

static void au_read_process(MSFilter *f){
	AudioUnitHolder *au_holder = [AudioUnitHolder sharedInstance];
	au_filter_read_data_t *d=(au_filter_read_data_t*)f->data;
	mblk_t *m;

	//bool_t read_something = FALSE; (never used, commented)
	/*
	If audio unit is not started, it means audsion session is not yet activated. Do not ms_ticker_synchronizer_update.
	*/
	if ([au_holder audio_unit_state] != MSAudioUnitStarted) return;

	ms_mutex_lock(&d->mutex);
	while((m = getq(&d->rq)) != NULL){
		d->read_samples += (msgdsize(m) / 2) / [au_holder nchannels];
		ms_queue_put(f->outputs[0],m);
	}
	ms_mutex_unlock(&d->mutex);

	ms_ticker_synchronizer_update(d->ticker_synchronizer, d->read_samples, [au_holder rate]);
}

static void au_read_postprocess(MSFilter *f){
	au_filter_read_data_t *d= (au_filter_read_data_t*)f->data;
	ms_mutex_lock(&d->mutex);
	flushq(&d->rq,0);
	ms_ticker_set_synchronizer(f->ticker, NULL);
	ms_ticker_synchronizer_destroy(d->ticker_synchronizer);
	[[AudioUnitHolder sharedInstance] setRead_started:FALSE];
	ms_mutex_unlock(&d->mutex);
}

/***********************************write function********************/

static void au_write_preprocess(MSFilter *f){
	ms_debug("au_write_preprocess");
	
	au_filter_write_data_t *d= (au_filter_write_data_t*)f->data;
	AudioUnitHolder *au_holder = [AudioUnitHolder sharedInstance];
	
	[au_holder check_audio_unit_is_up];
	/*configure our flow-control buffer*/
	ms_flow_controlled_bufferizer_set_samplerate(d->bufferizer, [au_holder rate]);
	ms_flow_controlled_bufferizer_set_nchannels(d->bufferizer, [au_holder nchannels]);
	[au_holder setWrite_started:TRUE];
}

static void au_write_process(MSFilter *f){
	ms_debug("au_write_process");
	au_filter_write_data_t *d=(au_filter_write_data_t*)f->data;

	if (d->base.muted || [[AudioUnitHolder sharedInstance] audio_unit_state] != MSAudioUnitStarted){
		ms_queue_flush(f->inputs[0]);
		return;
	}
	ms_mutex_lock(&d->mutex);
	ms_flow_controlled_bufferizer_put_from_queue(d->bufferizer, f->inputs[0]);
	ms_mutex_unlock(&d->mutex);
}

static void au_write_postprocess(MSFilter *f){
	ms_debug("au_write_postprocess");
	au_filter_write_data_t *d= (au_filter_write_data_t*)f->data;
	ms_mutex_lock(&d->mutex);
	ms_flow_controlled_bufferizer_flush(d->bufferizer);
	ms_mutex_unlock(&d->mutex);
	[[AudioUnitHolder sharedInstance] setWrite_started:FALSE];
}



static int read_set_rate(MSFilter *f, void *arg){
	AudioUnitHolder *au_holder = [AudioUnitHolder sharedInstance];
	int proposed_rate = *((int*)arg);
	ms_debug("set_rate %d",proposed_rate);
	/*The AudioSession must be configured before we decide of which sample rate we will use*/
	[au_holder configure_audio_session];
	if ((unsigned int)proposed_rate != [au_holder rate]){
		return -1;//only support 1 rate
	} else {
		return 0;
	}
}

static int write_set_rate(MSFilter *f, void *arg){
	AudioUnitHolder *au_holder = [AudioUnitHolder sharedInstance];
	int proposed_rate = *((int*)arg);
	ms_debug("set_rate %d",proposed_rate);
	/*The AudioSession must be configured before we decide of which sample rate we will use*/
	[au_holder configure_audio_session];
	if ((unsigned int)proposed_rate != [au_holder rate]){
		return -1;//only support 1 rate
	} else {
		return 0;
	}
}

static int get_rate(MSFilter *f, void *data){
	AudioUnitHolder *au_holder = [AudioUnitHolder sharedInstance];
	[au_holder configure_audio_session];
	*(int*)data= [au_holder rate];
	return 0;
}

static int set_nchannels(MSFilter *f, void *arg){
	ms_debug("set_nchannels %d", *((int*)arg));
	[[AudioUnitHolder sharedInstance] setNchannels:*(int*)arg];
	return 0;
}

static int get_nchannels(MSFilter *f, void *data) {
	*(int *)data = [[AudioUnitHolder sharedInstance] nchannels];
	return 0;
}

static int mute_mic(MSFilter *f, void *data){
    UInt32 enableMic = *((bool *)data) ? 0 : 1;
	AudioUnitHolder *au_holder = [AudioUnitHolder sharedInstance];
    
    if (enableMic == [au_holder mic_enabled])
        return 0;
    
	[au_holder setMic_enabled:enableMic];
    OSStatus auresult;
    
    if ([au_holder audio_unit_state] != MSAudioUnitStarted) {
        auresult=AudioUnitSetProperty ([au_holder audio_unit],
                                       kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input,
                                       inputBus,
                                       &enableMic,
                                       sizeof (enableMic)
                                       );
        check_au_unit_result(auresult,"kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input");
    } else {
		[au_holder stop_audio_unit_with_param:TRUE];
        [au_holder configure_audio_unit];
		[au_holder start_audio_unit:0];
    }
    
    return 0;
}

static int set_muted(MSFilter *f, void *data){
	au_filter_base_t *d=(au_filter_base_t*)f->data;
	d->muted = *(int*)data;
	return 0;
}

static int audio_playback_set_internal_id(MSFilter *f, void * newSndCard)
{
	AudioUnitHolder *au_holder = [AudioUnitHolder sharedInstance];
	MSSndCard *newCard = (MSSndCard *)newSndCard;
	MSSndCard *oldCard = [au_holder ms_snd_card];
	
	// Handle the internal linphone part with the MSSndCards
	if (strcmp(newCard->name, oldCard->name)==0) {
		return 0;
	}
	[au_holder mutex_lock];
	[au_holder setMs_snd_card:newSndCard];
	[au_holder mutex_unlock];
	
	// Make sure the apple audio route matches this state
	AVAudioSession *audioSession = [AVAudioSession sharedInstance];
	AVAudioSessionRouteDescription *currentRoute = [audioSession currentRoute];
	NSError *err=nil;
	if (newCard->device_type == MS_SND_CARD_DEVICE_TYPE_SPEAKER && currentRoute.outputs[0].portType != AVAudioSessionPortBuiltInSpeaker) {
		// If we're switching to speaker and the route output isn't the speaker already
		[audioSession overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&err];
	}
	else {
		// As AudioSession do not allow a way to nicely change the output port except with the override to Speaker,
		// we assume that input ports also come with a playback port (bluetooth earpiece, headset...) and change the input port.
		NSString *newPortName = [NSString stringWithUTF8String:newCard->name];
		NSArray *inputs = [audioSession availableInputs];
		for (AVAudioSessionPortDescription *input in inputs) {
			if ([input.portName isEqualToString:newPortName ]) {
				[audioSession setPreferredInput:input error:&err];
				break;
			}
		}
	}
	return 0;
}

static MSFilterMethod au_read_methods[]={
	{	MS_FILTER_SET_SAMPLE_RATE		 , read_set_rate					},
	{	MS_FILTER_GET_SAMPLE_RATE		 , get_rate							},
	{	MS_FILTER_SET_NCHANNELS			 , set_nchannels					},
	{	MS_FILTER_GET_NCHANNELS			 , get_nchannels					},
	{	MS_AUDIO_CAPTURE_MUTE			 , mute_mic 						},
	{	MS_AUDIO_CAPTURE_SET_INTERNAL_ID , audio_playback_set_internal_id	},
	{	0				, NULL		}
};

static MSFilterMethod au_write_methods[]={
	{	MS_FILTER_SET_SAMPLE_RATE	, write_set_rate							},
	{	MS_FILTER_GET_SAMPLE_RATE	, get_rate									},
	{	MS_FILTER_SET_NCHANNELS		, set_nchannels								},
	{	MS_FILTER_GET_NCHANNELS		, get_nchannels								},
	{	MS_AUDIO_PLAYBACK_MUTE	 	, set_muted									},
	{	MS_AUDIO_PLAYBACK_SET_INTERNAL_ID	, audio_playback_set_internal_id	},
	{	0				, NULL		}
};

static void au_read_uninit(MSFilter *f) {
	AudioUnitHolder *au_holder = [AudioUnitHolder sharedInstance];
	au_filter_read_data_t *d=(au_filter_read_data_t*)f->data;

	[au_holder mutex_lock];
	[au_holder setRead_filter:NULL];
	[au_holder mutex_unlock];

	check_unused();

	ms_mutex_destroy(&d->mutex);

	flushq(&d->rq,0);
	ms_free(d);
}

static void au_write_uninit(MSFilter *f) {
	au_filter_write_data_t *d=(au_filter_write_data_t*)f->data;
	AudioUnitHolder *au_holder = [AudioUnitHolder sharedInstance];

	[au_holder mutex_lock];
	[au_holder setWrite_filter:NULL];
	[au_holder mutex_unlock];

	check_unused();

	ms_mutex_destroy(&d->mutex);
	ms_flow_controlled_bufferizer_destroy(d->bufferizer);
	ms_free(d);
}

MSFilterDesc au_read_desc={
.id=MS_IOUNIT_READ_ID,
.name="MSAURead",
.text=N_("Sound capture filter for iOS Audio Unit Service"),
.category=MS_FILTER_OTHER,
.ninputs=0,
.noutputs=1,
.preprocess=au_read_preprocess,
.process=au_read_process,
.postprocess=au_read_postprocess,
.uninit=au_read_uninit,
.methods=au_read_methods
};


MSFilterDesc au_write_desc={
.id=MS_IOUNIT_WRITE_ID,
.name="MSAUWrite",
.text=N_("Sound playback filter for iOS Audio Unit Service"),
.category=MS_FILTER_OTHER,
.ninputs=1,
.noutputs=0,
.preprocess=au_write_preprocess,
.process=au_write_process,
.postprocess=au_write_postprocess,
.uninit=au_write_uninit,
.methods=au_write_methods
};

// This interface gives the impression that there will be 2 different MSSndCard for the Read filter and the Write filter.
// In reality, we'll always be using a single same card for both.
static MSFilter *ms_au_read_new(MSSndCard *mscard){
	ms_debug("ms_au_read_new");
	AudioUnitHolder *au_holder = [AudioUnitHolder sharedInstance];
	[au_holder setMs_snd_card:mscard];
	MSFilter *f=ms_factory_create_filter_from_desc(ms_snd_card_get_factory(mscard), &au_read_desc);
	au_filter_read_data_t *d=ms_new0(au_filter_read_data_t,1);
	qinit(&d->rq);
	d->readTimeStamp.mSampleTime=-1;
	ms_mutex_init(&d->mutex,NULL);
	[au_holder setRead_filter:f];
	f->data=d;
	return f;
}

static MSFilter *ms_au_write_new(MSSndCard *mscard){
	ms_debug("ms_au_write_new");
	AudioUnitHolder *au_holder = [AudioUnitHolder sharedInstance];
	[au_holder setMs_snd_card:mscard];
	MSFilter *f=ms_factory_create_filter_from_desc(ms_snd_card_get_factory(mscard), &au_write_desc);
	au_filter_write_data_t *d=ms_new0(au_filter_write_data_t,1);
	d->bufferizer= ms_flow_controlled_bufferizer_new(f, [au_holder rate], [au_holder nchannels]);
	ms_flow_controlled_bufferizer_set_max_size_ms(d->bufferizer, flowControlThreshold);
	ms_flow_controlled_bufferizer_set_flow_control_interval_ms(d->bufferizer, flowControlInterval);
	ms_mutex_init(&d->mutex,NULL);
	[au_holder setWrite_filter:f];
	f->data=d;
	return f;
}

MS_FILTER_DESC_EXPORT(au_read_desc)
MS_FILTER_DESC_EXPORT(au_write_desc)
