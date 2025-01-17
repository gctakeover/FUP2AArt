//
//  FUOpenGLView.m
//  FULiveDemo
//
//  Created by 刘洋 on 2017/8/15.
//  Copyright © 2017年 刘洋. All rights reserved.
//


#import <CoreVideo/CoreVideo.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>

#define STRINGIZE(x)    #x
#define STRINGIZE2(x)    STRINGIZE(x)
#define SHADER_STRING(text) @ STRINGIZE2(text)

NSString *const FUYUVToRGBAFragmentShaderString = SHADER_STRING
(
 varying highp vec2 textureCoordinate;
 
 uniform sampler2D luminanceTexture;
 uniform sampler2D chrominanceTexture;
 uniform mediump mat3 colorConversionMatrix;
 
 void main()
 {
	mediump vec3 yuv;
	lowp vec3 rgb;
	
	yuv.x = texture2D(luminanceTexture, textureCoordinate).r;
	yuv.yz = texture2D(chrominanceTexture, textureCoordinate).rg - vec2(0.5, 0.5);
	rgb = colorConversionMatrix * yuv;
	
	gl_FragColor = vec4(rgb, 1.0);
}
 );

NSString *const FURGBAFragmentShaderString = SHADER_STRING
(
 uniform sampler2D inputImageTexture;
 
 varying highp vec2 textureCoordinate;
 
 void main()
{
	gl_FragColor = vec4(texture2D(inputImageTexture, textureCoordinate).rgb,1.0);
}
 );

NSString *const FUVertexShaderString = SHADER_STRING
(
 attribute vec4 position;
 attribute vec4 inputTextureCoordinate;
 
 varying vec2 textureCoordinate;
 
 void main()
 {
	gl_Position = position;
	textureCoordinate = inputTextureCoordinate.xy;
}
 );

NSString *const FUPointsFrgShaderString = SHADER_STRING
(
 precision mediump float;
 
 varying highp vec4 fragmentColor;
 
 void main()
{
	gl_FragColor = fragmentColor;
}
 
 );

NSString *const FUPointsVtxShaderString = SHADER_STRING
(
 attribute vec4 position;
 
 attribute float point_size;
 
 attribute vec4 inputColor;
 
 varying vec4 fragmentColor;
 
 void main()
{
	gl_Position = position;
	
	gl_PointSize = point_size;
	
	fragmentColor = inputColor;
}
 );

enum
{
	furgbaPositionAttribute,
	furgbaTextureCoordinateAttribute,
	fuPointSize,
	fuPointColor,
};

enum
{
	fuyuvConversionPositionAttribute,
	fuyuvConversionTextureCoordinateAttribute
};

@interface FUOpenGLView()

@property (nonatomic, strong) EAGLContext *glContext;
@property (nonatomic, strong) CAEAGLLayer *eaglLayer;

@property(nonatomic) dispatch_queue_t contextQueue;

@end

@implementation FUOpenGLView
{
	GLuint rgbaProgram;
	GLuint rgbaToYuvProgram;
	GLuint pointProgram;
	
	CVOpenGLESTextureCacheRef videoTextureCache;
	
	GLuint frameBufferHandle;
	GLuint renderBufferHandle;
	
	GLint yuvConversionLuminanceTextureUniform, yuvConversionChrominanceTextureUniform;
	GLint yuvConversionMatrixUniform;
	GLint displayInputTextureUniform;
	
	GLfloat vertices[8];
	
	int frameWidth;
	int frameHeight;
	int backingWidth;
	int backingHeight;
	
	CGSize boundsSizeAtFrameBufferEpoch;
}

+ (Class)layerClass
{
	return [CAEAGLLayer class];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder
{
	if (self = [super initWithCoder:aDecoder]) {
		openGLBufferSize = self.frame.size;
		_contextQueue = dispatch_queue_create("com.faceunity.contextQueue", DISPATCH_QUEUE_SERIAL);
		
		self.contentScaleFactor = [[UIScreen mainScreen] scale];
		
		CAEAGLLayer *eaglLayer = (CAEAGLLayer *)self.layer;
		
		eaglLayer.opaque = TRUE;
		eaglLayer.drawableProperties = @{ kEAGLDrawablePropertyRetainedBacking :[NSNumber numberWithBool:NO],
										  kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8};
		
		_glContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
		
		if (!self.glContext) {
			NSLog(@"failed to create context");
		}
		
		if (!videoTextureCache) {
			CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, self.glContext, NULL, &videoTextureCache);
			if (err != noErr) {
				NSLog(@"Error at CVOpenGLESTextureCacheCreate %d", err);
			}
		}
		self.eaglLayer = (CAEAGLLayer *)self.layer;
		[self glkViewTest];
	}
	
	return self;
}
CGSize openGLBufferSize;
- (instancetype)initWithFrame:(CGRect)frame{
	if (self = [super initWithFrame:frame] ) {
		openGLBufferSize = frame.size;
		_contextQueue = dispatch_queue_create("com.faceunity.contextQueue", DISPATCH_QUEUE_SERIAL);
		self.contentScaleFactor = [[UIScreen mainScreen] scale];
		
		CAEAGLLayer *eaglLayer = (CAEAGLLayer *)self.layer;
		
		eaglLayer.opaque = TRUE;
		eaglLayer.drawableProperties = @{ kEAGLDrawablePropertyRetainedBacking :[NSNumber numberWithBool:NO],
										  kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8};
		
		_glContext = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
		
		if (!self.glContext) {
			NSLog(@"failed to create context");
			return nil;
		}
		
		if (!videoTextureCache) {
			CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, self.glContext, NULL, &videoTextureCache);
			if (err != noErr) {
				NSLog(@"Error at CVOpenGLESTextureCacheCreate %d", err);
			}
		}
		self.eaglLayer = (CAEAGLLayer *)self.layer;
		[self glkViewTest];
	}
	return self;
}

- (void)layoutSubviews{
	
	[super layoutSubviews];
	
	// The frame buffer needs to be trashed and re-created when the view size changes.
	if (!CGSizeEqualToSize(self.bounds.size, boundsSizeAtFrameBufferEpoch) &&
		!CGSizeEqualToSize(self.bounds.size, CGSizeZero)) {
		
		boundsSizeAtFrameBufferEpoch = self.bounds.size;
		
		dispatch_sync(_contextQueue, ^{
			[self destroyDisplayFramebuffer];
			[self createDisplayFramebuffer];
			[self updateMAXVertices];
		});
	}
}

- (void)dealloc
{
	dispatch_sync(_contextQueue, ^{
		[self destroyDisplayFramebuffer];
		[self destoryProgram];
		
		if(self->videoTextureCache) {
			CFRelease(self->videoTextureCache);
			self->videoTextureCache = NULL;
		}
	});
}
-(CVPixelBufferRef)createPixelBufferWithSize:(CGSize)size {
	const void *keys[] = {
		kCVPixelBufferOpenGLESCompatibilityKey,
		kCVPixelBufferIOSurfacePropertiesKey,
	};
	const void *values[] = {
		(__bridge const void *)([NSNumber numberWithBool:YES]),
		(__bridge const void *)([NSDictionary dictionary])
	};
	
	OSType bufferPixelFormat = kCVPixelFormatType_32BGRA;
	
	CFDictionaryRef optionsDictionary = CFDictionaryCreate(NULL, keys, values, 2, NULL, NULL);
	
	CVPixelBufferRef pixelBuffer = NULL;
	CVPixelBufferCreate(kCFAllocatorDefault,
						size.width,
						size.height,
						bufferPixelFormat,
						optionsDictionary,
						&pixelBuffer);
	
	CFRelease(optionsDictionary);
	
	return pixelBuffer;
}
typedef void (^CompleteBlock)(void);
CompleteBlock _completeBlock;
-(void)playDefaultAvatarInOpengl:(CompleteBlock)completeBlock{
	_completeBlock = completeBlock;
	
	CADisplayLink * displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkMethod)];
	displayLink.preferredFramesPerSecond = 30;
	[displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
	
	
}

-(void)displayLinkMethod{ }
typedef struct{
	GLKVector3 positionCoords;
}SceneVertex;

static const SceneVertex vertices[] = {
	{{-0.5f,-0.4f,0.0}},
	{{0.5f,-0.4f,0.0}},
	{{-0.5f,0.4f,0.0}},
	{{0.5f,0.4f,0.0}}
};
-(void)glkViewTest{
	return;
	UIView *view = (UIView *)self;
	
	
	
	self.baseEffect = [[GLKBaseEffect alloc] init];
	self.baseEffect.useConstantColor = GL_TRUE;
	self.baseEffect.constantColor = GLKVector4Make(1.0f,//red
												   1.0f,//green
												   1.0f,//blue
												   1.0f);
	
	self.vertexBuffer = [[AGLKVertexAttribArrayBuffer alloc] initWithAttribStride:sizeof(SceneVertex) numberOfVertices:sizeof(vertices)/sizeof(SceneVertex) data:vertices usage:GL_STATIC_DRAW];
	
}
-(void)displayLinkTest{
	glClear(GL_COLOR_BUFFER_BIT);
	glClearColor(0, 104.0/255.0, 55.0/255.0, 1.0);
	//	[self.baseEffect prepareToDraw];
	//    [self.vertexBuffer prepareToDrawWithAttrib:GLKVertexAttribPosition numberOfCoordinates:3 attribOffset:offsetof(SceneVertex, positionCoords) shouldEnable:YES];
	//    [self.vertexBuffer drawArrayWithMode:GL_TRIANGLE_STRIP startVertexIndex:0 numberOfVertices:4];
	
	
}
- (void)createDisplayFramebuffer
{
	[EAGLContext setCurrentContext:self.glContext];
	
	glDisable(GL_DEPTH_TEST);
	
	glGenFramebuffers(1, &frameBufferHandle);
	glBindFramebuffer(GL_FRAMEBUFFER, frameBufferHandle);
	
	glGenRenderbuffers(1, &renderBufferHandle);
	glBindRenderbuffer(GL_RENDERBUFFER, renderBufferHandle);
	
	[self.glContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:self.eaglLayer];
	//  [self.glContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:(CAEAGLLayer *)self.layer];
	
	glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &backingWidth);
	glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &backingHeight);
	
	if ( (backingWidth == 0) || (backingHeight == 0) )
	{
		[self destroyDisplayFramebuffer];
		return;
	}
	
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, renderBufferHandle);
	
	if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
		NSLog(@"Failed to make complete framebuffer object %x", glCheckFramebufferStatus(GL_FRAMEBUFFER));
	}
}

- (void)destroyDisplayFramebuffer;
{
	[EAGLContext setCurrentContext:self.glContext];
	
	if (frameBufferHandle)
	{
		glDeleteFramebuffers(1, &frameBufferHandle);
		frameBufferHandle = 0;
	}
	
	if (renderBufferHandle)
	{
		glDeleteRenderbuffers(1, &renderBufferHandle);
		renderBufferHandle = 0;
	}
}

- (void)setDisplayFramebuffer;
{
	if (!frameBufferHandle)
	{
		[self createDisplayFramebuffer];
	}
	
	glBindFramebuffer(GL_FRAMEBUFFER, frameBufferHandle);
	
	glViewport(0, 0, (GLint)backingWidth, (GLint)backingHeight);
}

- (void)destoryProgram{
	if (rgbaProgram) {
		glDeleteProgram(rgbaProgram);
		rgbaProgram = 0;
	}
	
	if (rgbaToYuvProgram) {
		glDeleteProgram(rgbaToYuvProgram);
		rgbaToYuvProgram = 0;
	}
	
	if (pointProgram) {
		glDeleteProgram(pointProgram);
		pointProgram = 0;
	}
}

- (void)presentFramebuffer;
{
	glBindRenderbuffer(GL_RENDERBUFFER, renderBufferHandle);
	[self.glContext presentRenderbuffer:GL_RENDERBUFFER];
	
	//  glFinish() ;
}

- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
	[self displayPixelBuffer:pixelBuffer withLandmarks:NULL count:0 Mirr:NO];
}

// 画横屏   18 : 16
- (void)display18R16PixelBuffer:(CVPixelBufferRef)pixelBuffer withLandmarks:(float *)landmarks count:(int)count Mirr:(BOOL) mirr
{
    if (pixelBuffer == NULL) return;
    CVPixelBufferRetain(pixelBuffer);
    dispatch_sync(_contextQueue, ^{
        
        self->frameWidth = (int)CVPixelBufferGetWidth(pixelBuffer);
        self->frameHeight = (int)CVPixelBufferGetHeight(pixelBuffer);
        
        if ([EAGLContext currentContext] != self.glContext) {
            if (![EAGLContext setCurrentContext:self.glContext]) {
                NSLog(@"fail to setCurrentContext");
            }
        }
        
        [self setDisplayFramebuffer];
        
        OSType type = CVPixelBufferGetPixelFormatType(pixelBuffer);
        if (type == kCVPixelFormatType_32BGRA)
        {
            [self prepareToDraw18R16BGRAPixelBuffer:pixelBuffer Mirr:mirr];
            
        }else{
            [self prepareToDrawYUVPixelBuffer:pixelBuffer];
        }
        
        CVPixelBufferRelease(pixelBuffer);
        
        if (landmarks) {
            [self prepareToDrawLandmarks:landmarks count:count];
        }
        
        [self presentFramebuffer];
    });
    
}

// 更新 18 ： 16 的顶点
- (void)update18R16Vertices
{
    const float width   = frameHeight;
    const float height  =   frameWidth;
    
    const float view_width = backingWidth;
    const float view_height = view_width * 16 / 18.0;
    // 以宽为主
    const float h       = view_height / (float)backingHeight;
    const float w       = 1;
    
    vertices[0] = - w;
    vertices[1] = - h;
    vertices[2] =   w;
    vertices[3] = - h;
    vertices[4] = - w;
    vertices[5] =   h;
    vertices[6] =   w;
    vertices[7] =   h;
}

// 画横屏  18 : 16
- (void)prepareToDraw18R16BGRAPixelBuffer:(CVPixelBufferRef)pixelBuffer Mirr:(BOOL)mirr
{
    if (!rgbaProgram) {
        [self loadShadersRGBA];
    }
    
    CVOpenGLESTextureRef rgbaTexture = NULL;
    CVReturn err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, videoTextureCache, pixelBuffer, NULL, GL_TEXTURE_2D, GL_RGBA, frameWidth, frameHeight, GL_BGRA, GL_UNSIGNED_BYTE, 0, &rgbaTexture);
    
    if (!rgbaTexture || err) {
        
        NSLog(@"Camera CVOpenGLESTextureCacheCreateTextureFromImage failed (error: %d)", err);
        return;
    }
    
    glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(rgbaTexture));
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    
    glUseProgram(rgbaProgram);
    
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    
    glActiveTexture(GL_TEXTURE4);
    glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(rgbaTexture));
    glUniform1i(displayInputTextureUniform, 4);
    
    [self update18R16Vertices];
    
    // 更新顶点数据
    glVertexAttribPointer(furgbaPositionAttribute, 2, GL_FLOAT, 0, 0, vertices);
    glEnableVertexAttribArray(furgbaPositionAttribute);
    float w = frameWidth;
    float h = w * 16 / 18.0;
    float s = 1.0;
    float t = (frameHeight - h) / frameHeight  / 2.0;
    GLfloat quadTextureData[] =  {
        0.0f,  1-t,
        s,  1-t,
        0.0f, t,
        s,  t,
    };
    
    if (mirr) {
        quadTextureData[0] = s;
        quadTextureData[1] = 1-t ;
        quadTextureData[2] = 0.0 ;
        quadTextureData[3] = 1-t ;
        
        quadTextureData[4] = s ;
        quadTextureData[5] = t ;
        quadTextureData[6] = 0.0 ;
        quadTextureData[7] = t ;
        
        
        
    }
    
    glVertexAttribPointer(furgbaTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, quadTextureData);
    glEnableVertexAttribArray(furgbaTextureCoordinateAttribute);
    
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    
    if (rgbaTexture) {
        CFRelease(rgbaTexture);
        rgbaTexture = NULL;
    }
}


- (void)prepareToDrawLandmarks:(float *)landmarks count:(int)count {
    if (!pointProgram) {
        [self loadPointsShaders];
    }
    
    glUseProgram(pointProgram);
    
    count = count/2;
    
    float sizeData[count];
    
    float colorData[count * 4];
    
    const float width   = frameWidth;
    const float height  = frameHeight;
    const float dH      = (float)backingHeight / height;
    const float dW      = (float)backingWidth  / width;
    const float dd      = MAX(dH, dW);
    const float h       = (height * dd / (float)backingHeight);
    const float w       = (width  * dd / (float)backingWidth );
    
    for (int i = 0; i < count; i++)
    {
        //点的大小
        sizeData[i] = [UIScreen mainScreen].scale * 1.5;
        
        //点的颜色
        colorData[4 * i] = 0.0;
        colorData[4 * i + 1] = 1.0;
        colorData[4 * i + 2] = 0.0;
        colorData[4 * i + 3] = 1.0;
        
        //转化坐标
        landmarks[2 * i] = (float)((2 * landmarks[2 * i] / frameWidth - 1))* +w;
        landmarks[2 * i + 1] = (float)(1 - 2 * landmarks[2 * i + 1] / frameHeight)*h;
    }
    
    glEnableVertexAttribArray(fuPointSize);
    glVertexAttribPointer(fuPointSize, 1, GL_FLOAT, GL_FALSE, 0, sizeData);
    
    glEnableVertexAttribArray(GLKVertexAttribPosition);
    glVertexAttribPointer(GLKVertexAttribPosition, 2, GL_FLOAT, GL_FALSE, 0, (GLfloat *)landmarks);
    
    glEnableVertexAttribArray(fuPointColor);
    glVertexAttribPointer(fuPointColor, 4, GL_FLOAT, GL_FALSE, 0, colorData);
    
    glDrawArrays(GL_POINTS, 0, count);
}


/// 将buffer显示到屏幕上 默认buffer将会铺满整个屏幕
/// @param pixelBuffer 输入源
/// @param landmarks 脸部点位
/// @param count 脸部点位数量
/// @param mirr 是否镜像
- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer withLandmarks:(float *)landmarks count:(int)count Mirr:(BOOL) mirr
{
	[self displayPixelBuffer:pixelBuffer withLandmarks:landmarks count:count bufferMirr:mirr landmarksMirr:mirr ShouldSpreadScreen:YES];
}
/// 将buffer显示到屏幕上
/// @param pixelBuffer 输入源
/// @param landmarks 脸部点位
/// @param count 脸部点位数量
/// @param spreadScreen 显示的texture是否铺满整个屏幕，YES为是，NO如果buffer不能刚好铺满屏幕，则会显示黑边
/// @param bufferMirr 是否镜像buffer
/// @param landmarksMirr 是否镜像脸部点位
- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer withLandmarks:(float *)landmarks count:(int)count bufferMirr:(BOOL)bufferMirr landmarksMirr:(BOOL)landmarksMirr ShouldSpreadScreen:(BOOL)spreadScreen
{
	if (pixelBuffer == NULL) return;
	CVPixelBufferRetain(pixelBuffer);
	dispatch_sync(_contextQueue, ^{
		
		self->frameWidth = (int)CVPixelBufferGetWidth(pixelBuffer);
		self->frameHeight = (int)CVPixelBufferGetHeight(pixelBuffer);
		
		if ([EAGLContext currentContext] != self.glContext) {
			if (![EAGLContext setCurrentContext:self.glContext]) {
				NSLog(@"fail to setCurrentContext");
			}
		}
		
		[self setDisplayFramebuffer];
		
		OSType type = CVPixelBufferGetPixelFormatType(pixelBuffer);
		if (type == kCVPixelFormatType_32BGRA)
		{
			[self prepareToDrawBGRAPixelBuffer:pixelBuffer Mirr:bufferMirr ShouldSpreadScreen:spreadScreen];
			
		}else{
			[self prepareToDrawYUVPixelBuffer:pixelBuffer];
		}
		
		CVPixelBufferRelease(pixelBuffer);
		
		if (landmarks) {
			[self prepareToDrawLandmarks:landmarks count:count Mirr:landmarksMirr];
		}
		
		[self presentFramebuffer];
	});
	
}
// 画横屏
- (void)displayLandscapePixelBuffer:(CVPixelBufferRef)pixelBuffer withLandmarks:(float *)landmarks count:(int)count Mirr:(BOOL) mirr
{
	if (pixelBuffer == NULL) return;
	CVPixelBufferRetain(pixelBuffer);
	dispatch_sync(_contextQueue, ^{
		
		self->frameWidth = (int)CVPixelBufferGetWidth(pixelBuffer);
		self->frameHeight = (int)CVPixelBufferGetHeight(pixelBuffer);
		
		if ([EAGLContext currentContext] != self.glContext) {
			if (![EAGLContext setCurrentContext:self.glContext]) {
				NSLog(@"fail to setCurrentContext");
			}
		}
		
		[self setDisplayFramebuffer];
		
		OSType type = CVPixelBufferGetPixelFormatType(pixelBuffer);
		if (type == kCVPixelFormatType_32BGRA)
		{
			[self prepareToDrawLandscapeBGRAPixelBuffer:pixelBuffer Mirr:mirr];
			
		}else{
			[self prepareToDrawYUVPixelBuffer:pixelBuffer];
		}
		
		CVPixelBufferRelease(pixelBuffer);
		
		if (landmarks) {
			[self prepareToDrawLandmarks:landmarks count:count  Mirr:mirr];
		}
		
		[self presentFramebuffer];
	});
	
}




- (void)convertMirrorPixelBuffer:(CVPixelBufferRef)pixelBuffer dstPixelBuffer:(CVPixelBufferRef*)dstPixelBuffer
{
	
	if (appManager.OpenGLESCapture)
	{
		glInsertEventMarkerEXT(0, "com.apple.GPUTools.event.debug-frame");
	}
	appManager.OpenGLESCapture = false;
	CVPixelBufferRetain(pixelBuffer);
	dispatch_sync(_contextQueue, ^{
		
		self->frameWidth = (int)CVPixelBufferGetWidth(pixelBuffer);
		self->frameHeight = (int)CVPixelBufferGetHeight(pixelBuffer);
		
		if ([EAGLContext currentContext] != self.glContext) {
			if (![EAGLContext setCurrentContext:self.glContext]) {
				NSLog(@"fail to setCurrentContext");
			}
		}
		
		[self setDisplayFramebuffer];
		
		OSType type = CVPixelBufferGetPixelFormatType(pixelBuffer);
		if (type == kCVPixelFormatType_32BGRA)
		{
			[self prepareToDrawBGRAPixelBuffer:pixelBuffer Mirr:true ShouldSpreadScreen:YES];
			
		}else{
			[self prepareToDrawYUVPixelBuffer:pixelBuffer];
		}
		*dstPixelBuffer = pixelBuffer;
		CVPixelBufferRelease(pixelBuffer);
		
		
	});
	
}
CVOpenGLESTextureCacheRef videoTextureCache1 = NULL;
- (void)convertMirrorPixelBuffer2:(CVPixelBufferRef)pixelBuffer dstPixelBuffer:(CVPixelBufferRef*)dstPixelBuffer{
	CVPixelBufferRetain(pixelBuffer);
	dispatch_sync(_contextQueue, ^{
		
		self->frameWidth = (int)CVPixelBufferGetWidth(pixelBuffer);
		self->frameHeight = (int)CVPixelBufferGetHeight(pixelBuffer);
		
		if ([EAGLContext currentContext] != self.glContext) {
			if (![EAGLContext setCurrentContext:self.glContext]) {
				NSLog(@"fail to setCurrentContext");
			}
		}
		
		[self setDisplayFramebuffer];
		
		
		CVReturn err0 = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, self.glContext, NULL, &videoTextureCache1);
		if (err0 != noErr) {
			NSLog(@"Error at CVOpenGLESTextureCacheCreate %d", err0);
		}
		if (!rgbaProgram) {
			[self loadShadersRGBA];
		}
		
		CVOpenGLESTextureRef rgbaTexture = NULL;
		CVReturn err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, videoTextureCache1, pixelBuffer, NULL, GL_TEXTURE_2D, GL_RGBA, frameWidth, frameHeight, GL_BGRA, GL_UNSIGNED_BYTE, 0, &rgbaTexture);
		
		if (!rgbaTexture || err) {
			
			NSLog(@"Camera CVOpenGLESTextureCacheCreateTextureFromImage failed (error: %d)", err);
			return;
		}
		
		glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(rgbaTexture));
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
		
		glUseProgram(rgbaProgram);
		
		glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);
		
		glActiveTexture(GL_TEXTURE4);
		glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(rgbaTexture));
		glUniform1i(displayInputTextureUniform, 4);
		
		[self updateMAXVertices];
		
		// 更新顶点数据
		glVertexAttribPointer(furgbaPositionAttribute, 2, GL_FLOAT, 0, 0, vertices);
		glEnableVertexAttribArray(furgbaPositionAttribute);
		
		GLfloat quadTextureData[] =  {
			0.0f, 1.0f,
			1.0f, 1.0f,
			0.0f,  0.0f,
			1.0f,  0.0f,
		};
		
		if (true) {
			
			quadTextureData[0] = 1.0 ;
			quadTextureData[2] = 0.0 ;
			quadTextureData[4] = 1.0 ;
			quadTextureData[6] = 0.0 ;
		}
		
		glVertexAttribPointer(furgbaTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, quadTextureData);
		glEnableVertexAttribArray(furgbaTextureCoordinateAttribute);
		
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
		
		if (rgbaTexture) {
			CFRelease(rgbaTexture);
			rgbaTexture = NULL;
		}
		[self createCVBufferWithSize:CGSizeMake(frameWidth, frameHeight) withRenderTarget:dstPixelBuffer withTextureOut:&rgbaTexture];
	});
}

- (void)createCVBufferWithSize:(CGSize)size
			  withRenderTarget:(CVPixelBufferRef *)target
				withTextureOut:(CVOpenGLESTextureRef *)texture {
	CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, self.glContext, NULL, &videoTextureCache1);
	if (err) return;
	CFDictionaryRef empty; // empty value for attr value.
	CFMutableDictionaryRef attrs;
	empty = CFDictionaryCreate(kCFAllocatorDefault, // our empty IOSurface properties dictionary
							   NULL,
							   NULL,
							   0,
							   &kCFTypeDictionaryKeyCallBacks,
							   &kCFTypeDictionaryValueCallBacks);
	attrs = CFDictionaryCreateMutable(kCFAllocatorDefault, 1,
									  &kCFTypeDictionaryKeyCallBacks,
									  &kCFTypeDictionaryValueCallBacks);
	CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, empty);
	CVPixelBufferCreate(kCFAllocatorDefault, size.width, size.height,
						kCVPixelFormatType_32BGRA, attrs, target);
	CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
												 videoTextureCache1,
												 *target,
												 NULL, // texture attributes
												 GL_TEXTURE_2D,
												 GL_RGBA, // opengl format
												 size.width,
												 size.height,
												 GL_BGRA, // native iOS format
												 GL_UNSIGNED_BYTE,
												 0,
												 texture);
	CFRelease(empty);
	CFRelease(attrs);
}



- (void)prepareToDrawLandmarks:(float *)landmarks count:(int)count Mirr:(BOOL) mirr
{
	if (!pointProgram) {
		[self loadPointsShaders];
	}
	
	glUseProgram(pointProgram);
	
	count = count/2;
	
	float sizeData[count];
	
	float colorData[count * 4];
	
	const float width   = frameWidth;
	const float height  = frameHeight;
	const float dH      = (float)backingHeight / height;
	const float dW      = (float)backingWidth  / width;
	const float dd      = MAX(dH, dW);
	const float h       = (height * dd / (float)backingHeight);
	const float w       = (width  * dd / (float)backingWidth );
	
	for (int i = 0; i < count; i++)
	{
		//点的大小
		sizeData[i] = [UIScreen mainScreen].scale * 1.5;
		
		//点的颜色
		colorData[4 * i] = 0.0;
		colorData[4 * i + 1] = 1.0;
		colorData[4 * i + 2] = 0.0;
		colorData[4 * i + 3] = 1.0;
		
		//转化坐标
		if (mirr){
		landmarks[2 * i] = (float)((2 * landmarks[2 * i] / frameWidth - 1))* +w;
		}else{
		landmarks[2 * i] = (float)((2 * landmarks[2 * i] / frameWidth - 1))* -w;
		}
		landmarks[2 * i + 1] = (float)(1 - 2 * landmarks[2 * i + 1] / frameHeight)*h;
	}
	
	glEnableVertexAttribArray(fuPointSize);
	glVertexAttribPointer(fuPointSize, 1, GL_FLOAT, GL_FALSE, 0, sizeData);
	
	glEnableVertexAttribArray(GLKVertexAttribPosition);
	glVertexAttribPointer(GLKVertexAttribPosition, 2, GL_FLOAT, GL_FALSE, 0, (GLfloat *)landmarks);
	
	glEnableVertexAttribArray(fuPointColor);
	glVertexAttribPointer(fuPointColor, 4, GL_FLOAT, GL_FALSE, 0, colorData);
	
	glDrawArrays(GL_POINTS, 0, count);
}

/// 将buffer转为texture，贴到view上
/// @param pixelBuffer 输入源
/// @param mirr 是否镜像
/// @param spreadScreen 显示的texture是否铺满整个屏幕，YES为是，NO如果buffer不能刚好铺满屏幕，则会显示黑边
- (void)prepareToDrawBGRAPixelBuffer:(CVPixelBufferRef)pixelBuffer Mirr:(BOOL)mirr ShouldSpreadScreen:(BOOL)spreadScreen
{
	if (!rgbaProgram) {
		[self loadShadersRGBA];
	}
	
	CVOpenGLESTextureRef rgbaTexture = NULL;
	CVReturn err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, videoTextureCache, pixelBuffer, NULL, GL_TEXTURE_2D, GL_RGBA, frameWidth, frameHeight, GL_BGRA, GL_UNSIGNED_BYTE, 0, &rgbaTexture);
	
	if (!rgbaTexture || err) {
		
		NSLog(@"Camera CVOpenGLESTextureCacheCreateTextureFromImage failed (error: %d)", err);
		return;
	}
	
	glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(rgbaTexture));
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	
	glUseProgram(rgbaProgram);
	
	glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	
	glActiveTexture(GL_TEXTURE4);
	glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(rgbaTexture));
	glUniform1i(displayInputTextureUniform, 4);
	if (spreadScreen) {
	[self updateMAXVertices];
	}else{
	[self updateMINVertices];
	}
	
	// 更新顶点数据
	glVertexAttribPointer(furgbaPositionAttribute, 2, GL_FLOAT, 0, 0, vertices);
	glEnableVertexAttribArray(furgbaPositionAttribute);
	
	GLfloat quadTextureData[] =  {
		0.0f, 1.0f,
		1.0f, 1.0f,
		0.0f,  0.0f,
		1.0f,  0.0f,
	};
	
	if (mirr) {
		
		quadTextureData[0] = 1.0 ;
		quadTextureData[2] = 0.0 ;
		quadTextureData[4] = 1.0 ;
		quadTextureData[6] = 0.0 ;
	}
	
	glVertexAttribPointer(furgbaTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, quadTextureData);
	glEnableVertexAttribArray(furgbaTextureCoordinateAttribute);
	
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	
	if (rgbaTexture) {
		CFRelease(rgbaTexture);
		rgbaTexture = NULL;
	}
}
// 画横屏
- (void)prepareToDrawLandscapeBGRAPixelBuffer:(CVPixelBufferRef)pixelBuffer Mirr:(BOOL)mirr
{
	if (!rgbaProgram) {
		[self loadShadersRGBA];
	}
	
	CVOpenGLESTextureRef rgbaTexture = NULL;
	CVReturn err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, videoTextureCache, pixelBuffer, NULL, GL_TEXTURE_2D, GL_RGBA, frameWidth, frameHeight, GL_BGRA, GL_UNSIGNED_BYTE, 0, &rgbaTexture);
	
	if (!rgbaTexture || err) {
		
		NSLog(@"Camera CVOpenGLESTextureCacheCreateTextureFromImage failed (error: %d)", err);
		return;
	}
	
	glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(rgbaTexture));
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	
	glUseProgram(rgbaProgram);
	
	glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	
	glActiveTexture(GL_TEXTURE4);
	glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(rgbaTexture));
	glUniform1i(displayInputTextureUniform, 4);
	
	[self updateLandscapeVertices];
	
	// 更新顶点数据
	glVertexAttribPointer(furgbaPositionAttribute, 2, GL_FLOAT, 0, 0, vertices);
	glEnableVertexAttribArray(furgbaPositionAttribute);
	
	GLfloat quadTextureData[] =  {

		1.0f, 1.0f,
		1.0f,  0.0f,
		0.0f,  1.0f,
		0.0f, 0.0f,
	};
	
	if (mirr) {
		
		quadTextureData[0] = 1.0 ;
		quadTextureData[2] = 0.0 ;
		quadTextureData[4] = 1.0 ;
		quadTextureData[6] = 0.0 ;
	}
	
	glVertexAttribPointer(furgbaTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, quadTextureData);
	glEnableVertexAttribArray(furgbaTextureCoordinateAttribute);
	
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	
	if (rgbaTexture) {
		CFRelease(rgbaTexture);
		rgbaTexture = NULL;
	}
}


- (void)prepareToDrawYUVPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
	if (!rgbaToYuvProgram) {
		[self loadShadersYUV];
	}
	
	CVReturn err;
	CVOpenGLESTextureRef luminanceTextureRef = NULL;
	CVOpenGLESTextureRef chrominanceTextureRef = NULL;
	
	/*
	 CVOpenGLESTextureCacheCreateTextureFromImage will create GLES texture optimally from CVPixelBufferRef.
	 */
	
	/*
	 Create Y and UV textures from the pixel buffer. These textures will be drawn on the frame buffer Y-plane.
	 */
	glActiveTexture(GL_TEXTURE0);
	err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
													   videoTextureCache,
													   pixelBuffer,
													   NULL,
													   GL_TEXTURE_2D,
													   GL_RED_EXT,
													   frameWidth,
													   frameHeight,
													   GL_RED_EXT,
													   GL_UNSIGNED_BYTE,
													   0,
													   &luminanceTextureRef);
	if (err) {
		NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
	}
	
	glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(luminanceTextureRef));
	glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	
	// UV-plane.
	glActiveTexture(GL_TEXTURE1);
	err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
													   videoTextureCache,
													   pixelBuffer,
													   NULL,
													   GL_TEXTURE_2D,
													   GL_RG_EXT,
													   frameWidth / 2,
													   frameHeight / 2,
													   GL_RG_EXT,
													   GL_UNSIGNED_BYTE,
													   1,
													   &chrominanceTextureRef);
	if (err) {
		NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
	}
	
	glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(chrominanceTextureRef));
	glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	
	glClearColor(0.1f, 0.0f, 0.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	
	// Use shader program.
	glUseProgram(rgbaToYuvProgram);
	
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(luminanceTextureRef));
	glUniform1i(yuvConversionLuminanceTextureUniform, 0);
	
	glActiveTexture(GL_TEXTURE1);
	glBindTexture(GL_TEXTURE_2D, CVOpenGLESTextureGetName(chrominanceTextureRef));
	glUniform1i(yuvConversionChrominanceTextureUniform, 1);
	
	GLfloat kColorConversion601FullRange[] = {
		1.0,    1.0,    1.0,
		0.0,    -0.343, 1.765,
		1.4,    -0.711, 0.0,
	};
	
	glUniformMatrix3fv(yuvConversionMatrixUniform, 1, GL_FALSE, kColorConversion601FullRange);
	
	// 更新顶点数据
	[self updateMAXVertices];
	
	glVertexAttribPointer(fuyuvConversionPositionAttribute, 2, GL_FLOAT, 0, 0, vertices);
	glEnableVertexAttribArray(fuyuvConversionPositionAttribute);
	
	GLfloat quadTextureData[] =  {
		0.0f, 1.0f,
		1.0f, 1.0f,
		0.0f,  0.0f,
		1.0f,  0.0f,
	};
	
	glVertexAttribPointer(fuyuvConversionTextureCoordinateAttribute, 2, GL_FLOAT, 0, 0, quadTextureData);
	glEnableVertexAttribArray(fuyuvConversionTextureCoordinateAttribute);
	
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	
	if (luminanceTextureRef) {
		CFRelease(luminanceTextureRef);
		luminanceTextureRef = NULL;
	}
	
	if (chrominanceTextureRef) {
		CFRelease(chrominanceTextureRef);
		chrominanceTextureRef = NULL;
	}
	
}

/// 显示的buffer，会铺满整个界面
- (void)updateMAXVertices
{
	const float width   = frameWidth;
	const float height  = frameHeight;
	const float dH      = (float)backingHeight / height;
	const float dW      = (float)backingWidth      / width;
	const float dd      = MAX(dH, dW);
	const float h       = (height * dd / (float)backingHeight);
	const float w       = (width  * dd / (float)backingWidth );
	
	vertices[0] = - w;
	vertices[1] = - h;
	vertices[2] =   w;
	vertices[3] = - h;
	vertices[4] = - w;
	vertices[5] =   h;
	vertices[6] =   w;
	vertices[7] =   h;
}
/// 显示的buffer，如果不能刚好铺满整个界面，则会显示黑边
- (void)updateMINVertices
{
	const float width   = frameWidth;
	const float height  = frameHeight;
	const float dH      = (float)backingHeight / height;
	const float dW      = (float)backingWidth      / width;
	const float dd      = MIN(dH, dW);
	const float h       = (height * dd / (float)backingHeight);
	const float w       = (width  * dd / (float)backingWidth );
	
	vertices[0] = - w;
	vertices[1] = - h;
	vertices[2] =   w;
	vertices[3] = - h;
	vertices[4] = - w;
	vertices[5] =   h;
	vertices[6] =   w;
	vertices[7] =   h;
}
- (void)updateLandscapeVertices
{

	vertices[0] = - 1;
	vertices[1] = - 1;
	vertices[2] =   1;
	vertices[3] = - 1;
	vertices[4] = - 1;
	vertices[5] =   1;
	vertices[6] =   1;
	vertices[7] =   1;
}



#pragma mark -  OpenGL ES 2 shader compilation

- (BOOL)loadShadersRGBA
{
	GLuint vertShader, fragShader;
	
	if (!rgbaProgram) {
		rgbaProgram = glCreateProgram();
	}
	
	// Create and compile the vertex shader.
	if (![self compileShader:&vertShader type:GL_VERTEX_SHADER string:FUVertexShaderString]) {
		NSLog(@"Failed to compile vertex shader");
		return NO;
	}
	
	// Create and compile fragment shader.
	if (![self compileShader:&fragShader type:GL_FRAGMENT_SHADER string:FURGBAFragmentShaderString]) {
		NSLog(@"Failed to compile fragment shader");
		return NO;
	}
	
	// Attach vertex shader to program.
	glAttachShader(rgbaProgram, vertShader);
	
	// Attach fragment shader to program.
	glAttachShader(rgbaProgram, fragShader);
	
	// Bind attribute locations. This needs to be done prior to linking.
	glBindAttribLocation(rgbaProgram, furgbaPositionAttribute, "position");
	glBindAttribLocation(rgbaProgram, furgbaTextureCoordinateAttribute, "inputTextureCoordinate");
	
	// Link the program.
	if (![self linkProgram:rgbaProgram]) {
		NSLog(@"Failed to link program: %d", rgbaProgram);
		
		if (vertShader) {
			glDeleteShader(vertShader);
			vertShader = 0;
		}
		if (fragShader) {
			glDeleteShader(fragShader);
			fragShader = 0;
		}
		if (rgbaProgram) {
			glDeleteProgram(rgbaProgram);
			rgbaProgram = 0;
		}
		
		return NO;
	}
	
	// Get uniform locations.
	displayInputTextureUniform = glGetUniformLocation(rgbaProgram, "inputImageTexture");
	
	// Release vertex and fragment shaders.
	if (vertShader) {
		glDetachShader(rgbaProgram, vertShader);
		glDeleteShader(vertShader);
	}
	if (fragShader) {
		glDetachShader(rgbaProgram, fragShader);
		glDeleteShader(fragShader);
	}
	
	return YES;
}

- (BOOL)loadShadersYUV
{
	GLuint vertShader, fragShader;
	
	if (!rgbaToYuvProgram) {
		rgbaToYuvProgram = glCreateProgram();
	}
	
	// Create and compile the vertex shader.
	if (![self compileShader:&vertShader type:GL_VERTEX_SHADER string:FUVertexShaderString]) {
		NSLog(@"Failed to compile vertex shader");
		return NO;
	}
	
	// Create and compile fragment shader.
	if (![self compileShader:&fragShader type:GL_FRAGMENT_SHADER string:FUYUVToRGBAFragmentShaderString]) {
		NSLog(@"Failed to compile fragment shader");
		return NO;
	}
	
	// Attach vertex shader to rgbaToYuvProgram.
	glAttachShader(rgbaToYuvProgram, vertShader);
	
	// Attach fragment shader to rgbaToYuvProgram.
	glAttachShader(rgbaToYuvProgram, fragShader);
	
	// Bind attribute locations. This needs to be done prior to linking.
	glBindAttribLocation(rgbaToYuvProgram, fuyuvConversionPositionAttribute, "position");
	glBindAttribLocation(rgbaToYuvProgram, fuyuvConversionTextureCoordinateAttribute, "inputTextureCoordinate");
	
	// Link the rgbaToYuvProgram.
	if (![self linkProgram:rgbaToYuvProgram]) {
		NSLog(@"Failed to link program: %d", rgbaToYuvProgram);
		
		if (vertShader) {
			glDeleteShader(vertShader);
			vertShader = 0;
		}
		if (fragShader) {
			glDeleteShader(fragShader);
			fragShader = 0;
		}
		if (rgbaToYuvProgram) {
			glDeleteProgram(rgbaToYuvProgram);
			rgbaToYuvProgram = 0;
		}
		
		return NO;
	}
	
	// Get uniform locations.
	yuvConversionLuminanceTextureUniform = glGetUniformLocation(rgbaToYuvProgram, "luminanceTexture");
	yuvConversionChrominanceTextureUniform = glGetUniformLocation(rgbaToYuvProgram, "chrominanceTexture");
	yuvConversionMatrixUniform = glGetUniformLocation(rgbaToYuvProgram, "colorConversionMatrix");
	
	// Release vertex and fragment shaders.
	if (vertShader) {
		glDetachShader(rgbaToYuvProgram, vertShader);
		glDeleteShader(vertShader);
	}
	if (fragShader) {
		glDetachShader(rgbaToYuvProgram, fragShader);
		glDeleteShader(fragShader);
	}
	
	glUseProgram(rgbaToYuvProgram);
	
	return YES;
}


- (BOOL)loadPointsShaders
{
	GLuint vertShader, fragShader;
	
	pointProgram = glCreateProgram();
	
	// Create and compile the vertex shader.
	if (![self compileShader:&vertShader type:GL_VERTEX_SHADER string:FUPointsVtxShaderString]) {
		NSLog(@"Failed to compile vertex shader");
		return NO;
	}
	
	// Create and compile fragment shader.
	if (![self compileShader:&fragShader type:GL_FRAGMENT_SHADER string:FUPointsFrgShaderString]) {
		NSLog(@"Failed to compile fragment shader");
		return NO;
	}
	
	// Attach vertex shader to program.
	glAttachShader(pointProgram, vertShader);
	
	// Attach fragment shader to program.
	glAttachShader(pointProgram, fragShader);
	
	// Bind attribute locations. This needs to be done prior to linking.
	glBindAttribLocation(pointProgram, fuPointSize, "point_size");
	glBindAttribLocation(pointProgram, fuPointColor, "inputColor");
	
	// Link the program.
	if (![self linkProgram:pointProgram]) {
		NSLog(@"Failed to link program: %d", pointProgram);
		
		if (vertShader) {
			glDeleteShader(vertShader);
			vertShader = 0;
		}
		if (fragShader) {
			glDeleteShader(fragShader);
			fragShader = 0;
		}
		if (pointProgram) {
			glDeleteProgram(pointProgram);
			pointProgram = 0;
		}
		
		return NO;
	}
	
	// Release vertex and fragment shaders.
	if (vertShader) {
		glDetachShader(pointProgram, vertShader);
		glDeleteShader(vertShader);
	}
	if (fragShader) {
		glDetachShader(pointProgram, fragShader);
		glDeleteShader(fragShader);
	}
	
	return YES;
}


- (BOOL)compileShader:(GLuint *)shader type:(GLenum)type string:(NSString *)shaderString
{
	GLint status;
	const GLchar *source;
	source = (GLchar *)[shaderString UTF8String];
	
	*shader = glCreateShader(type);
	glShaderSource(*shader, 1, &source, NULL);
	glCompileShader(*shader);
	
#if defined(DEBUG)
	GLint logLength;
	glGetShaderiv(*shader, GL_INFO_LOG_LENGTH, &logLength);
	if (logLength > 0) {
		GLchar *log = (GLchar *)malloc(logLength);
		glGetShaderInfoLog(*shader, logLength, &logLength, log);
		NSLog(@"Shader compile log:\n%s", log);
		free(log);
	}
#endif
	
	glGetShaderiv(*shader, GL_COMPILE_STATUS, &status);
	if (status == 0) {
		glDeleteShader(*shader);
		return NO;
	}
	
	return YES;
}

- (BOOL)linkProgram:(GLuint)prog
{
	GLint status;
	glLinkProgram(prog);
	
#if defined(DEBUG)
	GLint logLength;
	glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
	if (logLength > 0) {
		GLchar *log = (GLchar *)malloc(logLength);
		glGetProgramInfoLog(prog, logLength, &logLength, log);
		NSLog(@"Program link log:\n%s", log);
		free(log);
	}
#endif
	
	glGetProgramiv(prog, GL_LINK_STATUS, &status);
	if (status == 0) {
		return NO;
	}
	
	return YES;
}

- (BOOL)validateProgram:(GLuint)prog
{
	GLint logLength, status;
	
	glValidateProgram(prog);
	glGetProgramiv(prog, GL_INFO_LOG_LENGTH, &logLength);
	if (logLength > 0) {
		GLchar *log = (GLchar *)malloc(logLength);
		glGetProgramInfoLog(prog, logLength, &logLength, log);
		NSLog(@"Program validate log:\n%s", log);
		free(log);
	}
	
	glGetProgramiv(prog, GL_VALIDATE_STATUS, &status);
	if (status == 0) {
		return NO;
	}
	
	return YES;
}

@end
