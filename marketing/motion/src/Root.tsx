import {Composition} from 'remotion';
import {DemoGraphics, LowerThird, MetaStack, Pipeline, TitleCard} from './Scenes';
const video = {width: 1920, height: 1080, fps: 30};
export const Root = () => <>
  <Composition id="DemoGraphics" component={DemoGraphics} durationInFrames={1200} {...video}/>
  <Composition id="TitleCard" component={TitleCard} durationInFrames={150} {...video}/>
  <Composition id="Pipeline" component={Pipeline} durationInFrames={420} {...video}/>
  <Composition id="MetaStack" component={MetaStack} durationInFrames={420} {...video}/>
  <Composition id="LowerThird" component={LowerThird} durationInFrames={150} {...video}
    defaultProps={{title: 'Record your workout by voice', detail: 'Say the weight and repetitions. Setecho saves them.', preview: false}}/>
</>;
