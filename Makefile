CXX = clang++
CXXFLAGS = -std=c++17 -O3 -Wall -x objective-c++ -fobjc-arc
LDFLAGS = -framework AVFoundation -framework Foundation -framework Cocoa -framework Accelerate

TARGET = NoiseReductor
APP_BUNDLE = NoiseReductor.app
APP_BIN = $(APP_BUNDLE)/Contents/MacOS/$(TARGET)
SRC = App.mm
OBJ = $(SRC:.mm=.o)

all: $(APP_BIN)

$(APP_BIN): $(OBJ)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	$(CXX) $(OBJ) -o $(APP_BIN) $(LDFLAGS)

%.o: %.mm
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -f $(TARGET) $(APP_BIN) $(OBJ)
